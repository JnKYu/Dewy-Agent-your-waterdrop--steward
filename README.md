# Dewy macOS

Dewy is a local-first macOS desktop companion. Its floating blue orb sits at the lower-right edge of the screen. Hover to show the quick-entry card; click to open the 420 × 420 chat window.

## Run

1. Open `Dewy.app`, or use `./rebuild-and-launch.sh` to build, package, replace any running copy, and launch the latest version.
2. The first launch creates `~/Library/Application Support/Dewy/records.json`.
3. Use the controls in the chat header to set cup size, hydration goal, focus and break durations, quiet hours, and an optional model connection.

After changing source code, run `./rebuild-and-launch.sh`. A plain `swift build` only creates a new executable in `.build`; it does not update the app bundle or an already running app. The script updates the bundle's executable and build number, signs and verifies the app bundle, exits old copies, then launches the new version.

## Local commands

The core tracking actions work without an internet connection:

- `喝水` or `喝了 350ml`
- `新增待办：整理资料` and `完成：整理资料`
- `开始专注` / `结束专注`
- `工作记录：今天完成了…`
- `早餐：燕麦和牛奶`
- `睡眠 23:00-07:00`
- `目标：完成作品集`
- `今日总结` / `周总结` / `月总结`

Enter `帮助` in the chat for the in-app command list. Records are saved locally and can be exported as JSON. API keys are stored in macOS Keychain.

## Optional language model

Open Settings and provide a Gemini model name and API key for open-ended conversation. The key is stored in the macOS Keychain and sent in the `x-goog-api-key` request header. The default model is `gemini-3.8-flash`. When the model is not configured, Dewy uses local command handling and supportive fallback replies. Model replies do not write to the record store automatically.

### Connect Gemini

1. Open Dewy and click the Settings control.
2. Under “可选语言模型”, click “前往 Google AI Studio 创建或查看 API Key”.
3. Sign in to Google. In AI Studio, create or select a project, open API Keys, create a key, and copy it.
4. Return to Dewy, paste the key into the API Key field, leave the model as `gemini-3.8-flash`, and save.
5. Try a normal conversational message. Local commands such as `喝水` continue to work without the model.

Keep the key private. Paste it into Dewy, not into chat messages or source files. Dewy stores it in the macOS Keychain.

## Current scope

This first native version includes tasks, hydration, focus sessions, work notes, meals, sleep intervals, goals, and calendar day/week/month summaries. It also includes quiet-hour behavior and a visual hydration reminder that briefly pulses the orb. It does not yet integrate with Calendar, speech recognition, system notifications, or an automated SMART goal planner.
