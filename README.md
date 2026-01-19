<div align="center">
  <img src="VoiceInk/Assets.xcassets/AppIcon.appiconset/256-mac.png" width="180" height="180" />
  <h1>VoiceInk-Pro</h1>
  <p>Voice to text app for macOS to transcribe what you say to text almost instantly</p>
  <p><em>A custom fork of <a href="https://github.com/Beingpax/VoiceInk">VoiceInk</a> for custom usage</em></p>

  [![License](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
  ![Platform](https://img.shields.io/badge/platform-macOS%2014.0%2B-brightgreen)
</div>

---

## About VoiceInk-Pro

VoiceInk-Pro is a custom fork of the [VoiceInk](https://github.com/Beingpax/VoiceInk) project, created for custom usage and development. This repository is based on the open-source VoiceInk application, which is a native macOS application that transcribes what you say to text almost instantly.

![VoiceInk Mac App](https://github.com/user-attachments/assets/12367379-83e7-48a6-b52c-4488a6a04bba)

### Original Project

VoiceInk was created by [Pax](https://github.com/Beingpax) and is available at [https://github.com/Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk). The original project is licensed under GNU General Public License v3.0. For the official version with automatic updates, priority support, and upcoming features, please visit [tryvoiceink.com](https://tryvoiceink.com).

## Features

- 🎙️ **Accurate Transcription**: Local AI models that transcribe your voice to text with 99% accuracy, almost instantly
- 🔒 **Privacy First**: 100% offline processing ensures your data never leaves your device
- ⚡ **Power Mode**: Intelligent app detection automatically applies your perfect pre-configured settings based on the app/ URL you're on
- 🧠 **Context Aware**: Smart AI that understands your screen content and adapts to the context
- 🎯 **Global Shortcuts**: Configurable keyboard shortcuts for quick recording and push-to-talk functionality
- 📝 **Personal Dictionary**: Train the AI to understand your unique terminology with custom words, industry terms, and smart text replacements
- 🔄 **Smart Modes**: Instantly switch between AI-powered modes optimized for different writing styles and contexts
- 🤖 **AI Assistant**: Built-in voice assistant mode for a quick chatGPT like conversational assistant

## Get Started

### Build from Source
You can build VoiceInk-Pro from source by following the instructions in [BUILDING.md](BUILDING.md). 

**Note:** If you want the official VoiceInk version with automatic updates and priority support, please visit [tryvoiceink.com](https://tryvoiceink.com) or install via Homebrew:

```shell
brew install --cask voiceink
```

## Requirements

- macOS 14.0 or later

## Documentation

- [Building from Source](BUILDING.md) - Detailed instructions for building the project
- [Contributing Guidelines](CONTRIBUTING.md) - How to contribute to VoiceInk
- [Code of Conduct](CODE_OF_CONDUCT.md) - Our community standards

## Contributing

We welcome contributions! However, please note that all contributions should align with the project's goals and vision. Before starting work on any feature or fix:

1. Read our [Contributing Guidelines](CONTRIBUTING.md)
2. Open an issue to discuss your proposed changes
3. Wait for maintainer feedback

For build instructions, see our [Building Guide](BUILDING.md).

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

The original VoiceInk project is also licensed under the GNU General Public License v3.0. See the [original repository](https://github.com/Beingpax/VoiceInk) for more details.

## Support

If you encounter any issues or have questions, please:
1. Check the existing issues in the GitHub repository
2. Create a new issue if your problem isn't already reported
3. Provide as much detail as possible about your environment and the problem

## Acknowledgments

### Core Technology
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) - High-performance inference of OpenAI's Whisper model
- [FluidAudio](https://github.com/FluidInference/FluidAudio) - Used for Parakeet model implementation

### Essential Dependencies
- [Sparkle](https://github.com/sparkle-project/Sparkle) - Keeping VoiceInk up to date
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) - User-customizable keyboard shortcuts
- [LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin) - Launch at login functionality
- [MediaRemoteAdapter](https://github.com/ejbills/mediaremote-adapter) - Media playback control during recording
- [Zip](https://github.com/marmelroy/Zip) - File compression and decompression utilities
- [SelectedTextKit](https://github.com/tisfeng/SelectedTextKit) - A modern macOS library for getting selected text
- [Swift Atomics](https://github.com/apple/swift-atomics) - Low-level atomic operations for thread-safe concurrent programming


---

**Original VoiceInk** made with ❤️ by [Pax](https://github.com/Beingpax)  
**VoiceInk-Pro** customized by [Chabel Holdo BOSSA](https://github.com/chabelbossa)
