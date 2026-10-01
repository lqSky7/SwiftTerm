# cloud_object — index

StaticShareExport captures up to 20 recent sealed blocks as bounded plain text; no draft, cwd,
image or live IDs. SecretRedaction masks locally before editable selection/preview.
StaticShareCoordinator owns preparation/upload tasks and freezes the body/capability for retries.
StaticShareWindowController hosts the native preview, public publish link and revoke action.
AppCore composes this feature; it receives only the shared API, origin and terminal model.
