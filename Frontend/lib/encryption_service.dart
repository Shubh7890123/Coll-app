import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

import 'supabase_service.dart';

/// Proper End-to-End Encryption for Colony Chat.
///
/// Cryptographic building blocks:
///   - **Key exchange** : ECDH on NIST P-256 (secp256r1).
///     Both sides derive the *same* 32-byte shared secret.
///   - **Key derivation** : HKDF-SHA256 with a per-sender info string
///     so that Alice->Bob and Bob->Alice use different AES keys
///     (directional encryption prevents reflection attacks).
///   - **Message encryption** : AES-256-GCM with a random 12-byte nonce.
///     GCM provides both confidentiality and integrity (16-byte tag).
///   - **Wire format** : JSON stored in the `content` column:
///     ```
///     {
///       "v": 1,                  // scheme version
///       "ct": "<base64>",        // ciphertext + GCM tag
///       "iv": "<base64>",        // 12-byte nonce
///       "kh": "<hex>"            // first 8 hex chars of sender public-key hash
///     }
///     ```
class EncryptionService {
  static final EncryptionService _instance = EncryptionService._internal();
  factory EncryptionService() => _instance;
  EncryptionService._internal();

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _skKey = 'e2e_ec_private';
  static const _pkKey = 'e2e_ec_public';
  static const _schemeVersion = 1;

  ECPrivateKey? _privateKey;
  ECPublicKey? _publicKey;

  final Map<String, ECPublicKey> _peerKeyCache = {};
  final Map<String, Uint8List> _derivedKeyCache = {};

  bool get isReady => _privateKey != null && _publicKey != null;

  // ─── Initialisation ─────────────────────────────────────────────

  Future<void> initialize() async {
    try {
      final storedSk = await _storage.read(key: _skKey);
      final storedPk = await _storage.read(key: _pkKey);

      if (storedSk != null && storedPk != null) {
        _privateKey = _privateKeyFromBytes(base64Decode(storedSk));
        _publicKey = _publicKeyFromBytes(base64Decode(storedPk));
      }

      if (_privateKey == null || _publicKey == null) {
        await _generateKeyPair();
      }

      await _uploadPublicKeyIfNeeded();
    } catch (e) {
      print('Encryption init error: $e — regenerating keys');
      await _generateKeyPair();
    }
  }

  // ─── Key generation ─────────────────────────────────────────────

  static final _ecDomain = ECCurve_secp256r1();
  static final _ecParams = ECKeyGeneratorParameters(_ecDomain);

  Future<void> _generateKeyPair() async {
    final secureRandom = _getSecureRandom();
    final keyGen = ECKeyGenerator()
      ..init(ParametersWithRandom(_ecParams, secureRandom));

    final pair = keyGen.generateKeyPair();
    _privateKey = pair.privateKey as ECPrivateKey;
    _publicKey = pair.publicKey as ECPublicKey;

    await _storage.write(
      key: _skKey,
      value: base64Encode(_bigIntToFixedBytes(_privateKey!.d!, 32)),
    );
    await _storage.write(
      key: _pkKey,
      value: base64Encode(_publicKeyToBytes(_publicKey!)),
    );

    _derivedKeyCache.clear();
    await _uploadPublicKeyIfNeeded();
  }

  SecureRandom _getSecureRandom() {
    final secureRandom = FortunaRandom();
    final random = Random.secure();
    final seeds = Uint8List.fromList(
      List.generate(32, (_) => random.nextInt(256)),
    );
    secureRandom.seed(KeyParameter(seeds));
    return secureRandom;
  }

  // ─── Public key upload ──────────────────────────────────────────

  Future<void> _uploadPublicKeyIfNeeded() async {
    try {
      final user = SupabaseService().client.auth.currentUser;
      if (user == null || _publicKey == null) return;

      final pkBase64 = base64Encode(_publicKeyToBytes(_publicKey!));

      final existing = await SupabaseService().client
          .from('user_keys')
          .select('public_key')
          .eq('user_id', user.id)
          .maybeSingle();

      if (existing == null) {
        await SupabaseService().client.from('user_keys').insert({
          'user_id': user.id,
          'public_key': pkBase64,
          'key_version': _schemeVersion,
        });
      } else if (existing['public_key'] != pkBase64) {
        await SupabaseService().client
            .from('user_keys')
            .update({'public_key': pkBase64, 'key_version': _schemeVersion})
            .eq('user_id', user.id);
        _derivedKeyCache.clear();
      }
    } catch (e) {
      print('Error uploading public key: $e');
    }
  }

  // ─── Peer key fetching ──────────────────────────────────────────

  Future<ECPublicKey?> _getPeerPublicKey(String userId) async {
    if (_peerKeyCache.containsKey(userId)) {
      return _peerKeyCache[userId]!;
    }
    try {
      final row = await SupabaseService().client
          .from('user_keys')
          .select('public_key')
          .eq('user_id', userId)
          .maybeSingle();

      if (row != null && row['public_key'] != null) {
        final pk = _publicKeyFromBytes(
          base64Decode(row['public_key'] as String),
        );
        if (pk != null) {
          _peerKeyCache[userId] = pk;
          return pk;
        }
      }
    } catch (e) {
      print('Error fetching peer key for $userId: $e');
    }
    return null;
  }

  // ─── ECDH shared secret + HKDF ──────────────────────────────────

  Uint8List _ecdhSharedSecret(ECPublicKey peerPublic) {
    final dh = ECDHBasicAgreement()..init(_privateKey!);
    final shared = dh.calculateAgreement(peerPublic);
    return _bigIntToFixedBytes(shared, 32);
  }

  Uint8List _hkdfDeriveKey(Uint8List ikm, Uint8List info) {
    // HKDF-Extract: PRK = HMAC-SHA256(zero_salt, IKM)
    final extractHmac = HMac(SHA256Digest(), 64);
    final salt = Uint8List(32);
    extractHmac.init(KeyParameter(salt));
    extractHmac.update(ikm, 0, ikm.length);
    final prk = Uint8List(32);
    extractHmac.doFinal(prk, 0);

    // HKDF-Expand: OKM = HMAC-SHA256(PRK, info || 0x01)
    final expandHmac = HMac(SHA256Digest(), 64);
    expandHmac.init(KeyParameter(prk));
    expandHmac.update(info, 0, info.length);
    final t = Uint8List(1);
    t[0] = 0x01;
    expandHmac.update(t, 0, 1);
    final okm = Uint8List(32);
    expandHmac.doFinal(okm, 0);
    return okm;
  }

  Future<Uint8List> _getDerivedKey(
    String peerUserId, {
    required bool outgoing,
  }) async {
    final cacheKey = '${peerUserId}_${outgoing ? 'out' : 'in'}';
    if (_derivedKeyCache.containsKey(cacheKey)) {
      return _derivedKeyCache[cacheKey]!;
    }

    if (_privateKey == null) await initialize();
    if (_privateKey == null) throw Exception('Encryption not initialised');

    final peerPk = await _getPeerPublicKey(peerUserId);
    if (peerPk == null) throw Exception('No public key for user $peerUserId');

    final shared = _ecdhSharedSecret(peerPk);

    // Directional info so A->B and B->A use different keys
    final myId = SupabaseService().client.auth.currentUser!.id;
    final direction = outgoing ? '$myId->$peerUserId' : '$peerUserId->$myId';
    final info = Uint8List.fromList(utf8.encode('colony-e2e-v1:$direction'));

    final key = _hkdfDeriveKey(shared, info);
    _derivedKeyCache[cacheKey] = key;
    return key;
  }

  // ─── Encrypt / Decrypt ──────────────────────────────────────────

  Future<String> encrypt(String plaintext, String recipientId) async {
    final aesKey = await _getDerivedKey(recipientId, outgoing: true);

    final random = Random.secure();
    final nonce = Uint8List.fromList(
      List.generate(12, (_) => random.nextInt(256)),
    );

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(KeyParameter(aesKey), 128, nonce, Uint8List(0)),
      );

    final cipherText = cipher.process(
      Uint8List.fromList(utf8.encode(plaintext)),
    );

    final keyHint = _publicKeyHash8Hex(_publicKey!);

    final payload = {
      'v': _schemeVersion,
      'ct': base64Encode(cipherText),
      'iv': base64Encode(nonce),
      'kh': keyHint,
    };

    return jsonEncode(payload);
  }

  Future<String> decrypt(String encryptedJson, String peerId, {bool isOutgoing = false}) async {
    final map = jsonDecode(encryptedJson) as Map<String, dynamic>;

    final version = map['v'] as int? ?? 1;
    if (version != _schemeVersion) {
      throw Exception('Unsupported encryption version $version');
    }

    final ct = base64Decode(map['ct'] as String);
    final nonce = base64Decode(map['iv'] as String);

    final aesKey = await _getDerivedKey(peerId, outgoing: isOutgoing);

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(KeyParameter(aesKey), 128, nonce, Uint8List(0)),
      );

    final plainBytes = cipher.process(Uint8List.fromList(ct));
    return utf8.decode(plainBytes);
  }

  /// Try to decrypt; return null on any failure (fallback to raw text).
  Future<String?> tryDecrypt(String content, String peerId, {bool isOutgoing = false}) async {
    if (!isReady) return null;
    if (!content.trimLeft().startsWith('{')) return null;
    try {
      final map = jsonDecode(content) as Map<String, dynamic>;
      if (map['ct'] == null || map['iv'] == null) return null;
      return await decrypt(content, peerId, isOutgoing: isOutgoing);
    } catch (_) {
      return null;
    }
  }

  /// Whether a content string looks like our encrypted JSON payload.
  static bool isEncryptedPayload(String content) {
    if (!content.trimLeft().startsWith('{')) return false;
    try {
      final map = jsonDecode(content) as Map<String, dynamic>;
      return map['ct'] != null && map['iv'] != null;
    } catch (_) {
      return false;
    }
  }

  // ─── Cleanup ────────────────────────────────────────────────────

  Future<void> clearKeys() async {
    _privateKey = null;
    _publicKey = null;
    _peerKeyCache.clear();
    _derivedKeyCache.clear();
    await _storage.delete(key: _skKey);
    await _storage.delete(key: _pkKey);
  }

  // ─── Serialisation helpers ──────────────────────────────────────

  Uint8List _bigIntToFixedBytes(BigInt n, int width) {
    var hex = n.toRadixString(16);
    if (hex.length < width * 2) {
      hex = hex.padLeft(width * 2, '0');
    }
    if (hex.length > width * 2) {
      hex = hex.substring(hex.length - width * 2);
    }
    final bytes = Uint8List(width);
    for (var i = 0; i < width; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  ECPrivateKey? _privateKeyFromBytes(Uint8List bytes) {
    try {
      final d = _bytesToBigInt(bytes);
      return ECPrivateKey(d, _ecDomain);
    } catch (_) {
      return null;
    }
  }

  Uint8List _publicKeyToBytes(ECPublicKey pk) {
    final q = pk.Q!;
    final x = q.x!.toBigInteger()!;
    final y = q.y!.toBigInteger()!;
    return Uint8List.fromList([
      ..._bigIntToFixedBytes(x, 32),
      ..._bigIntToFixedBytes(y, 32),
    ]);
  }

  ECPublicKey? _publicKeyFromBytes(Uint8List bytes) {
    try {
      if (bytes.length != 64) return null;
      final x = _bytesToBigInt(Uint8List.sublistView(bytes, 0, 32));
      final y = _bytesToBigInt(Uint8List.sublistView(bytes, 32, 64));
      final point = _ecDomain.curve.createPoint(x, y);
      return ECPublicKey(point, _ecDomain);
    } catch (_) {
      return null;
    }
  }

  BigInt _bytesToBigInt(Uint8List bytes) {
    return BigInt.parse(
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16,
    );
  }

  String _publicKeyHash8Hex(ECPublicKey pk) {
    final pkBytes = _publicKeyToBytes(pk);
    final digest = SHA256Digest();
    final hash = digest.process(pkBytes);
    return hash
        .sublist(0, 4)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
