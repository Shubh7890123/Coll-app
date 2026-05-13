# Backend Setup with Supabase

## ⚠️ IMPORTANT: Currently Unused

**This Express.js backend is currently NOT USED by the Flutter frontend.**

The Flutter frontend communicates directly with Supabase using the `supabase_flutter` package. All database operations, authentication, and real-time features are handled through Supabase SDK.

See [`docs/BACKEND_STATUS.md`](../docs/BACKEND_STATUS.md) for detailed information about the current architecture and recommendations.

---

## Purpose of This Backend

This backend was originally designed to provide a REST API layer over Supabase. It is kept in the repository for potential future use cases:

- **Web Client**: If you build a web version that can't use Supabase SDK directly
- **Complex Business Logic**: Server-side operations that shouldn't be exposed to clients
- **Third-party Integrations**: Webhooks, payment processing, etc.
- **Admin Panel**: Separate admin interface with different permissions
- **Public API**: API for third-party developers

---

## Supabase Services Used

This backend is configured to use Supabase for the following services:
- **Auth** (Login/Signup)
- **PostgreSQL + PostGIS** (Location data)
- **Realtime** (Chat)
- **Storage** (Images)

## Configuration

### Environment Variables
Copy `.env.example` to `.env` and fill in your Supabase credentials:

```bash
cp .env.example .env
```

The `.env` file should contain:
- `SUPABASE_URL`: Your Supabase project URL
- `SUPABASE_ANON_KEY`: Your Supabase anonymous key
- `SUPABASE_SERVICE_ROLE_KEY`: Your Supabase service role key (keep secret)
- `SUPABASE_JWT_SECRET`: Your JWT secret from Supabase
- `REDIS_URL`: Redis connection URL (for caching/sessions)
- `PORT`: Server port (default: 3000)

### Supabase Setup
1. Create a Supabase project at [supabase.com](https://supabase.com)
2. Get your project URL and keys from Settings > API
3. Enable the required services:
   - Authentication
   - Database (PostgreSQL with PostGIS extension)
   - Realtime
   - Storage

## Installation

```bash
cd backend
npm install
```

## Running the Server

Development (with auto-restart):
```bash
npm run dev
```

Production:
```bash
npm start
```

## API Endpoints

- `GET /` - API information
- `GET /health` - Health check
- `GET /test-supabase` - Test Supabase connection

## Project Structure

```
backend/
├── index.js              # Main server entry point
├── package.json          # Dependencies
├── .env                  # Environment variables (gitignored)
├── .env.example          # Example environment variables
├── README.md             # This file
└── src/                  # Source code
    ├── config/           # Configuration files
    ├── services/         # Business logic
    ├── routes/           # API routes
    └── utils/            # Utility functions
```

## Current Status

### Implemented Endpoints (Not Used by Frontend)

The following endpoints are implemented in `index.js` but are NOT called by the Flutter frontend:

| Category | Endpoints |
|----------|-----------|
| Authentication | `POST /auth/signup`, `POST /auth/login`, `POST /auth/logout`, `GET /auth/user`, `POST /auth/reset-password`, `PATCH /auth/profile` |
| Profile | `GET /profile/:userId`, `PATCH /profile` |
| Groups | `POST /groups`, `GET /groups`, `POST /groups/:groupId/join` |
| Conversations | `GET /conversations`, `POST /conversations`, `GET /conversations/:id/messages`, `POST /conversations/:id/messages` |
| User Keys | `GET /user-keys/:userId`, `POST /user-keys` |

### Frontend Implementation

The Flutter frontend uses direct Supabase queries instead:

| Feature | Backend Endpoint | Frontend Implementation |
|---------|-----------------|------------------------|
| Authentication | `/auth/signup`, `/auth/login` | `supabase.auth.signUp()`, `supabase.auth.signInWithPassword()` |
| User Profiles | `/profile/:userId` | `supabase.from('profiles').select()` |
| Nearby Users | `/users/nearby` | `supabase.rpc('get_nearby_users')` |
| Nearby Groups | `/groups/nearby` | `supabase.rpc('get_nearby_groups')` |
| Stories | `/stories` | `supabase.from('stories').select()` |
| Waves | `/waves` | `supabase.from('waves').insert()` |
| Conversations | `/conversations` | `supabase.from('conversations').select()` |
| Messages | `/conversations/:id/messages` | `supabase.from('messages').insert()` |
| Real-time Updates | N/A | `supabase.channel().onPostgresChanges()` |

---

## Next Steps (If You Want to Use This Backend)

1. **Decide on Architecture**: Choose between direct Supabase (current) or backend API
2. **If Using Backend**: Update frontend to call backend endpoints instead of direct Supabase queries
3. **Implement Missing Endpoints**: See `docs/NOT_IMPLEMENTED_API.md` for endpoints not yet implemented
4. **Add JWT Validation**: Middleware to validate Supabase JWT tokens
5. **Gradual Migration**: Migrate one feature at a time, testing thoroughly

See [`docs/BACKEND_STATUS.md`](../docs/BACKEND_STATUS.md) for detailed migration guide.

## Security Notes

- Never commit `.env` file to version control
- Use environment variables for all secrets
- The service role key should only be used server-side
- Implement proper authentication and authorization