# Colony App

A location-based social media app built with Flutter and Supabase.

## Features

- **Location-based Discovery**: Find nearby users and groups within 5km radius
- **Wave System**: Send waves to connect with other users (mutual acceptance required for chat)
- **Real-time Chat**: End-to-end encrypted private messaging
- **Group Chat**: Create and join local groups
- **Stories**: Share 24-hour expiring stories
- **Device-first Auth**: PIN-based device authentication
- **Push Notifications**: Firebase Cloud Messaging for alerts
- **Dark/Light Theme**: Customizable theme support

## Architecture

### Current Setup

The app uses **Direct Supabase Integration** - the Flutter frontend communicates directly with Supabase using the Supabase Flutter SDK.

```
Flutter App → Supabase (Direct)
           ├─ Auth (Authentication)
           ├─ Database (PostgreSQL + PostGIS)
           ├─ Realtime (Chat/Notifications)
           └─ Storage (Images)
```

### Backend Status

The Express.js backend in the `backend/` directory is **currently used for Push Notifications (FCM) and WebRTC Signaling**. While the frontend uses Supabase directly for database operations, the Express backend acts as a microservice for delivering notifications and handling WebSockets.

See [`docs/BACKEND_STATUS.md`](docs/BACKEND_STATUS.md) for detailed information about the backend.

## Project Structure

```
colony-app/
├── Frontend/              # Flutter mobile app
│   ├── lib/
│   │   ├── screens/       # UI screens
│   │   ├── services/      # Service classes
│   │   └── config.dart   # Configuration
│   ├── .env              # Environment variables
│   └── pubspec.yaml      # Dependencies
├── backend/              # Express.js backend (currently unused)
│   ├── index.js          # Main server
│   ├── supabase/         # Database migrations
│   └── README.md        # Backend documentation
├── docs/                # Documentation
│   ├── API_DOCUMENTATION.md
│   ├── NOT_IMPLEMENTED_API.md
│   └── BACKEND_STATUS.md
└── README.md            # This file
```

## Getting Started

### Prerequisites

- Flutter SDK (3.11.4 or higher)
- Dart SDK
- Supabase account
- Firebase account (for push notifications)

### Frontend Setup

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd colony-app/Frontend
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Configure environment variables**
   
   Copy `.env` file and update with your Supabase credentials:
   ```bash
   # Frontend/.env
   SUPABASE_URL=https://your-project.supabase.co
   SUPABASE_ANON_KEY=your-anon-key
   ```

4. **Run the app**
   ```bash
   flutter run
   ```

### Supabase Setup

1. Create a new project at [supabase.com](https://supabase.com)
2. Enable the following services:
   - Authentication
   - Database (PostgreSQL with PostGIS extension)
   - Realtime
   - Storage
3. Run the database migrations from `backend/supabase/migrations/`
4. Configure Row Level Security (RLS) policies

### Firebase Setup (Optional - for Push Notifications)

1. Create a Firebase project at [console.firebase.google.com](https://console.firebase.google.com)
2. Add Android and iOS apps
3. Download `google-services.json` (Android) and `GoogleService-Info.plist` (iOS)
4. Place them in the respective platform folders

## Database Schema

The app uses the following main tables:

| Table | Purpose |
|-------|---------|
| `profiles` | User profiles with location |
| `stories` | User stories (24hr expiry) |
| `story_views` | Track story views |
| `groups` | User-created groups |
| `group_members` | Group membership |
| `waves` | Mutual wave system for chat enablement |
| `conversations` | Chat conversations |
| `messages` | Chat messages |
| `group_messages` | Group chat messages |
| `user_keys` | E2E encryption public keys |
| `user_fcm_tokens` | Push notification tokens |

See [`backend/supabase/migrations/COMPLETE_MIGRATION.sql`](backend/supabase/migrations/COMPLETE_MIGRATION.sql) for the complete schema.

## Security Features

- **Row Level Security (RLS)**: Database-level access control
- **End-to-End Encryption**: AES-256-GCM for private messages
- **Device Authentication**: PIN-based unlock
- **Secure Storage**: Flutter Secure Storage for sensitive data
- **JWT Authentication**: Supabase Auth with token management

## Documentation

- [`docs/API_DOCUMENTATION.md`](docs/API_DOCUMENTATION.md) - Complete API documentation
- [`docs/NOT_IMPLEMENTED_API.md`](docs/NOT_IMPLEMENTED_API.md) - Backend endpoints not yet implemented
- [`docs/BACKEND_STATUS.md`](docs/BACKEND_STATUS.md) - Backend status and recommendations
- [`backend/README.md`](backend/README.md) - Backend setup and documentation

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License.
