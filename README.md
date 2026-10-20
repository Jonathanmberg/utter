<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="Utter">
</p>

<h1 align="center">Utter</h1>

<p align="center">By Jonathan Berg · <a href="https://x.com/jbtradin">@jbtradin</a></p>

Utter is a teleprompter that hides behind your Mac's camera notch. Hover over the notch and click, and it drops down with your script right under the camera, so you can read while looking people in the eye on calls. Press play and the text scrolls; hover over it to pause. You can type or paste straight into it, color and box important words, and connect files (images, PDFs) to words so they pop up when you click them. Click the X and it tucks back behind the camera.

## Download

Get **Utter.dmg** from the [latest release](../../releases/latest), open it and drag Utter into Applications.

The first time you open it, macOS may say it can't verify the developer. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

## Build it yourself

```bash
./build.sh
```

Needs macOS 13+ and Xcode. The app ends up in `dist/`.
