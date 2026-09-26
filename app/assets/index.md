# App Assets

- `swiftTerm.icon/`: the app icon, as a macOS 26+ Icon Composer package — `icon.json` and the vector
  `Assets/SVG Image.svg`. **This is the only source of the app's icon.** `Scripts/build-app.sh` compiles
  it with `actool` into `Assets.car`, which is where the Liquid Glass layers and their light, dark and
  tinted appearances live, and actool also emits the flat `swiftTerm.icns` the bundle still carries.

  Two things about it are easy to get wrong, and both were:

  - **The package's name is the icon's name.** `actool --app-icon` has to match it, and so does
    `CFBundleIconName` in `app/Info.plist`. Give actool a name that matches no package and it does not
    fail — it compiles the layers under a name nothing looks up, emits no `.icns`, and exits zero. The
    app then falls back to a legacy `.icns`, which macOS 26 draws with its own container and a hard
    glass rim. The build script now asserts the `.icns` exists, because the failure is silent.
  - **`icon.json` is the art.** The gradient in it is what the mark is filled with; the icon this
    replaced ended on a saturated red that read as a harsh rim at the edges.

- `AppIcon-1024.png` and `AppIcon.icns`: **retired, and no longer shipped or referenced.** They were the
  flat icon — a 1024 render and an `iconutil` bundle built from it — from before the `.icon` package
  existed, and it is the legacy `.icns` half of that pair that macOS 26 was drawing instead of the
  compiled icon. Neither is read by anything now. They are left in place only because they are untracked
  and deleting them would be the only copy; they can go.
