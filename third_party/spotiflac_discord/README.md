# Playback presence

Small Android/iOS bridge to Discord's official Social SDK (tested with
1.10.19337). It publishes a Listening activity and never joins voice calls or
changes the app's audio session. The SDK is initialized only after opt-in.

## Build setup

Download the C++ Social SDK from the SpotiFLAC Mobile application's **Social SDK
→ Downloads** page in the Discord Developer Portal. Extract it, then run:

```sh
bash scripts/setup_discord_sdk.sh /path/to/discord_social_sdk
flutter pub get
```

On CI, provide the official SDK through the build environment and run the same
script before building. Vendor binaries and their license notices stay under
the ignored `sdk/` and `ios/Frameworks/` directories; do not commit developer credentials or rehost SDK
downloads. Distributions containing the SDK must include its license notices
and follow Discord's SDK terms. The setup script stages notices for inclusion
in Android assets and iOS resources. Without these files the app still builds, but
the presence setting reports that the SDK is unavailable. A clean clone alone
does not produce a Discord-enabled build.

To deliberately omit a staged SDK, set `SPOTIFLAC_DISCORD_SDK=0` during Android
builds or iOS `pod install` and app builds. `bash scripts/build_android.sh --lite`
sets this flag for Android. The bridge remains registered and reports presence
as unavailable; the staged SDK files are retained for subsequent full builds.

Production Android builds use `bash scripts/build_android.sh --production`,
which forces Discord on, checks the staged SDK and audits it in every APK ABI.
`--production --lite` is rejected. Release CI requires the SDK on both platforms
and stops before publication if the SDK is absent. Provision the official SDK
in the build environment before running that workflow.

Android uses the installed Discord app's signed-in session (Social SDK 1.10+).
The AAR and CMake use the same staged native library; the host packages one copy
with `jniLibs.pickFirsts`. Microphone/Bluetooth permissions and the SDK voice
service are removed by the host manifest. Do not remove the app's own audio
service or playback permissions.

iOS uses the SDK's OAuth PKCE flow with `openid sdk.social_layer_presence`.
SDK-enabled simulator builds require an Apple Silicon Mac (arm64). The setup
script stages an optional simulator configuration; builds without the SDK keep
Flutter's normal simulator architecture support.
Configure the application as a **Public Client**, and register exactly:

```text
discord-1549854098801692862:/authorize/callback
```

The Application ID is public. Never embed a client secret or a Discord user
token. Only the OAuth refresh token is persisted, using the host's secure
storage; access tokens stay in memory. Disabling presence clears the activity
and closes the SDK. Disconnecting also removes the locally stored refresh
token. Users can revoke authorization in Discord's Authorized Apps settings.

## Runtime

`DiscordPresenceService` subscribes to the audio handler, not a player widget.
Track/seek changes are coalesced to one update per 15 seconds. Pause, stop and
disable clear immediately. Presence displays title and artist only. Public
HTTPS artwork may include image-sizing parameters, but never credentials or
signed URL parameters. For local artwork, the resolver first checks download
history, then searches enabled metadata providers for an exact title,
artist and album match (and compatible duration). Results are cached, and late
lookups cannot update a different track or a disabled session. Local artwork
is never uploaded. If no public match exists, artwork is omitted; Discord
controls its own fallback presentation. SDK failures cannot interrupt music
playback. Presence depends on
Discord's activity privacy settings, connectivity and mobile background limits.

After staging the SDK, run `flutter test integration_test/discord_sdk_test.dart
-d <device-id>` on an iOS simulator or Android device to test native startup,
shutdown and restart without linking an account or publishing any activity.
