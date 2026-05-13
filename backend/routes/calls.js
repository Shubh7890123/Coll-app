const express = require('express');

function createCallsRouter({ callService }) {
  const router = express.Router();

  router.post('/start-call', async (req, res) => {
    try {
      const callerId = req.body.callerId || req.user.id;
      if (callerId !== req.user.id) {
        return res.status(403).json({ success: false, message: 'callerId must match authenticated user' });
      }

      const result = await callService.startCall({
        callerId,
        receiverId: req.body.receiverId,
        callType: req.body.callType,
      });

      res.status(201).json({ success: true, callId: result.callId, data: result });
    } catch (error) {
      const status = error.message.includes('busy') ? 409 : 400;
      res.status(status).json({ success: false, message: error.message });
    }
  });

  router.post('/accept-call', async (req, res) => {
    try {
      const result = await callService.acceptCall({
        callId: req.body.callId,
        userId: req.user.id,
      });
      res.status(200).json({ success: true, data: result });
    } catch (error) {
      res.status(400).json({ success: false, message: error.message });
    }
  });

  router.post('/reject-call', async (req, res) => {
    try {
      const result = await callService.rejectCall({
        callId: req.body.callId,
        userId: req.user.id,
      });
      res.status(200).json({ success: true, data: result });
    } catch (error) {
      res.status(400).json({ success: false, message: error.message });
    }
  });

  router.post('/cancel-call', async (req, res) => {
    try {
      const result = await callService.cancelCall({
        callId: req.body.callId,
        userId: req.user.id,
      });
      res.status(200).json({ success: true, data: result });
    } catch (error) {
      res.status(400).json({ success: false, message: error.message });
    }
  });

  router.post('/end-call', async (req, res) => {
    try {
      const result = await callService.endCall({
        callId: req.body.callId,
        userId: req.user.id,
      });
      res.status(200).json({ success: true, data: result });
    } catch (error) {
      res.status(400).json({ success: false, message: error.message });
    }
  });

  router.get('/history', async (req, res) => {
    try {
      const limit = Math.min(parseInt(req.query.limit, 10) || 50, 100);
      const offset = Math.max(parseInt(req.query.offset, 10) || 0, 0);
      const data = await callService.getHistory(req.user.id, { limit, offset });
      res.status(200).json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, message: error.message });
    }
  });

  router.get('/:callId', async (req, res) => {
    try {
      const data = await callService.getCall(req.params.callId, req.user.id);
      res.status(200).json({ success: true, data });
    } catch (error) {
      res.status(404).json({ success: false, message: error.message });
    }
  });

  return router;
}

module.exports = { createCallsRouter };
