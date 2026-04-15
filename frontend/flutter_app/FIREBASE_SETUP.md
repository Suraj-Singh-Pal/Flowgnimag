# Firebase Push Setup (FLOWGNIMAG)

This project now has FCM code and Android Gradle wiring. Complete these manual steps once per Firebase project.

## 1) Firebase Console
- Create/select your Firebase project.
- Add Android app package: `com.example.flutter_app` (or your final package id).
- Add iOS app bundle id (if using iOS).
- Enable **Cloud Messaging**.

## 2) Android setup
- Download `google-services.json` from Firebase Console.
- Put it at: `android/app/google-services.json`.
- Build/run after this file is added.

## 3) iOS setup
- Download `GoogleService-Info.plist` from Firebase Console.
- Put it at: `ios/Runner/GoogleService-Info.plist`.
- Open `ios/Runner.xcworkspace` in Xcode and ensure file is in Runner target.
- In Xcode Runner target:
  - Signing & Capabilities -> add `Push Notifications`.
  - Signing & Capabilities -> add `Background Modes` and enable `Remote notifications`.

## 4) Backend setup
Set these in `backend/.env` for server push:
- `FIREBASE_PROJECT_ID`
- `FIREBASE_CLIENT_EMAIL`
- `FIREBASE_PRIVATE_KEY`

## 5) Runtime verification
- Start backend and app.
- Login cloud account on app.
- Device token auto-registers to backend endpoint `/notifications/register`.
- Send test push with `POST /notifications/test` (auth required).

## Notes
- If you change Android package id or iOS bundle id, re-download Firebase config files.
- iOS build/capabilities must be configured from macOS/Xcode.
