# Edge Functions Deployment Guide

## Overview
This guide explains how to deploy Supabase Edge Functions for the Colony app.

## Prerequisites
- Supabase CLI installed (`npm install -g supabase`)
- Supabase project linked (`supabase link --project-ref YOUR_PROJECT_REF`)
- Environment variables configured

## Available Edge Functions

### 1. send-notification
**Location**: `backend/supabase/functions/send-notification/index.ts`

**Purpose**: Sends push notifications via Firebase Cloud Messaging (FCM) to users.

**Required Environment Variables**:
- `SUPABASE_URL` - Your Supabase project URL
- `SUPABASE_SERVICE_ROLE_KEY` - Your Supabase service role key
- `FIREBASE_PROJECT_ID` - Firebase project id
- `FIREBASE_CLIENT_EMAIL` - Service account client email
- `FIREBASE_PRIVATE_KEY` - Service account private key (`\n` escaped is fine)

## Deployment Steps

### Step 1: Link your Supabase project (if not already linked)
```bash
cd backend/supabase
supabase link --project-ref hicfazehsmeyobrasaie
```

### Step 2: Set environment variables locally
Create a `.env` file in `backend/supabase/`:
```env
SUPABASE_URL=https://hicfazehsmeyobrasaie.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your_service_role_key_here
FCM_SERVER_KEY=your_fcm_server_key_here
```

### Step 3: Deploy the Edge Function
```bash
cd backend/supabase
supabase functions deploy send-notification
```

### Step 4: Set environment variables in Supabase
After deployment, set the environment variables in your Supabase dashboard:
1. Go to https://supabase.com/dashboard/project/hicfazehsmeyobrasaie/functions
2. Click on "send-notification"
3. Go to "Environment Variables" section
4. Add the following variables:
   - `SUPABASE_URL`: `https://hicfazehsmeyobrasaie.supabase.co`
   - `SUPABASE_SERVICE_ROLE_KEY`: Your service role key (from Supabase dashboard > Settings > API)
   - `FIREBASE_PROJECT_ID`: from service account JSON (`project_id`)
   - `FIREBASE_CLIENT_EMAIL`: from service account JSON (`client_email`)
   - `FIREBASE_PRIVATE_KEY`: from service account JSON (`private_key`)

## Testing the Edge Function

### Test via curl:
```bash
curl -X POST 'https://hicfazehsmeyobrasaie.supabase.co/functions/v1/send-notification' \
  -H 'Authorization: Bearer YOUR_ANON_KEY' \
  -H 'Content-Type: application/json' \
  -d '{
    "target_user_id": "user_uuid_here",
    "title": "Test Notification",
    "body": "This is a test notification",
    "data": {
      "type": "message",
      "sender_id": "sender_uuid_here"
    }
  }'
```

## Troubleshooting

### Error: "FunctionException(status: 404, details: {code: NOT_FOUND, message: Requested function was not found}"
**Cause**: The Edge Function hasn't been deployed to Supabase.

**Solution**: Follow the deployment steps above.

### Error: "Missing required fields"
**Cause**: The request body is missing required fields (target_user_id, title, body).

**Solution**: Ensure all required fields are included in the request.

### Error: "User has no FCM token registered"
**Cause**: The target user hasn't registered their FCM token.

**Solution**: Ensure the user's device has registered their FCM token in the `user_fcm_tokens` table.

## Monitoring

View Edge Function logs:
```bash
supabase functions logs send-notification
```

Or view logs in the Supabase Dashboard:
1. Go to https://supabase.com/dashboard/project/hicfazehsmeyobrasaie/functions
2. Click on "send-notification"
3. View logs in the "Logs" section
