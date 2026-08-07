/*
 * Live Translate Settings View
 * Live translation settings screen
 *
 * BUILD 57 — this screen had drifted a long way from what the app actually
 * does. Three of its controls were inherited from the original Alibaba/Qwen
 * implementation and no longer connected to anything: an eight-voice picker
 * where six voices were "Chinese only" and none of them existed on Gemini, a
 * source-language list that quietly undid the English-always-your-side rule,
 * and a "visual enhancement" toggle whose real behaviour — a camera frame
 * uploaded twice a second — was described as helping with homophones.
 *
 * A settings screen that lies is worse than no settings screen: you change
 * something, nothing happens, and you stop trusting the app.
 */

import SwiftUI

struct LiveTranslateSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: LiveTranslateViewModel
    @AppStorage("translate_show_pronunciation") private var showPronunciation = true
    @AppStorage("chappy_tts_voice") private var appVoice = "Kore"

    var body: some View {
        NavigationView {
            List {

                // MARK: - Their language (the one that actually matters)

                Section {
                    ForEach(TranslateLanguage.targetLanguages) { language in
                        Button {
                            viewModel.targetLanguage = language
                        } label: {
                            HStack {
                                Text(language.flag)
                                    .font(.title2)
                                Text(language.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if viewModel.targetLanguage == language {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("They speak")
                } footer: {
                    Text("You always speak English. Chappy also switches this by itself if it hears two turns in a different language, and \"Chappy, translate Thai\" sets it by voice.")
                }

                // MARK: - Your language

                Section {
                    ForEach(TranslateLanguage.sourceLanguages) { language in
                        Button {
                            viewModel.sourceLanguage = language
                        } label: {
                            HStack {
                                Text(language.flag)
                                    .font(.title2)
                                Text(language.displayName)
                                    .foregroundColor(.primary)
                                Spacer()
                                if viewModel.sourceLanguage == language {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("You speak")
                } footer: {
                    Text("Only change this if you're not speaking English. Setting it to the local language tells the interpreter you're the local — which is how every sentence ends up filed on the wrong side.")
                }

                // MARK: - How it speaks

                Section {
                    Toggle(isOn: $viewModel.politeMode) {
                        HStack {
                            Image(systemName: viewModel.politeMode ? "hand.raised.fill" : "hand.wave")
                                .foregroundColor(.orange)
                            Text(viewModel.politeMode ? "Polite / formal" : "Casual")
                        }
                    }

                    Toggle(isOn: $viewModel.loudSpeaker) {
                        HStack {
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundColor(.pink)
                            Text("Loudspeaker (SPK)")
                        }
                    }

                    Toggle(isOn: $viewModel.audioOutputEnabled) {
                        HStack {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundColor(.blue)
                            Text("Speak translations aloud")
                        }
                    }

                    Toggle(isOn: $showPronunciation) {
                        HStack {
                            Image(systemName: "character.phonetic")
                                .foregroundColor(.teal)
                            Text("Pronunciation line (SAY)")
                        }
                    }
                } header: {
                    Text("Speech")
                } footer: {
                    Text("Polite is the register for landlords, officials and elders; casual is the street. Loudspeaker pushes sound out of the iPhone so a table can hear it while the glasses keep listening. Turn speech off entirely to read translations silently.")
                }

                // MARK: - Voice (points at the real one)

                Section {
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundColor(.purple)
                        Text("Voice")
                        Spacer()
                        Text(appVoice)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Translate speaks with the same voice as the rest of Chappy — change it in Settings → Voice. The old picker here listed Alibaba voices that Gemini has never had, so choosing one did nothing at all.")
                }

                // MARK: - Microphone

                Section {
                    Toggle(isOn: $viewModel.usePhoneMic) {
                        HStack {
                            Image(systemName: viewModel.usePhoneMic ? "iphone" : "airpodsmax")
                                .foregroundColor(.purple)
                            Text("Use iPhone microphone")
                        }
                    }
                } header: {
                    Text("Microphone")
                } footer: {
                    Text("Off uses the glasses mic, which is best for your own voice. On uses the iPhone, better when the phone is sitting between you and the other person. With no glasses connected it uses the iPhone regardless.")
                }

                // MARK: - Camera assist (renamed and costed honestly)

                Section {
                    Toggle(isOn: $viewModel.imageEnhanceEnabled) {
                        HStack {
                            Image(systemName: "camera.fill")
                                .foregroundColor(.green)
                            Text("Camera assist")
                        }
                    }
                } header: {
                    Text("Camera")
                } footer: {
                    Text("Sends a picture from the glasses about twice a second so the interpreter can see what you're both looking at — useful for a menu or a sign, and genuinely expensive. It also drains the glasses battery. Leave it off unless you need it for a specific conversation.")
                }

                // MARK: - Saved phrases

                if !viewModel.phrases.isEmpty {
                    Section {
                        HStack {
                            Image(systemName: "bookmark.fill")
                                .foregroundColor(.blue)
                            Text("Saved phrases")
                            Spacer()
                            Text("\(viewModel.phrases.count)")
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("Phrases")
                    } footer: {
                        Text("Open them from the bookmark on the Translate screen. They play with no connection at all.")
                    }
                }

                // MARK: - History

                if !viewModel.translationHistory.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            viewModel.clearHistory()
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Clear history")
                            }
                        }
                    } header: {
                        Text("History")
                    } footer: {
                        Text("\(viewModel.translationHistory.count) saved. Your saved phrases aren't affected.")
                    }
                }
            }
            .navigationTitle("Translation Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done".localized) {
                        dismiss()
                    }
                }
            }
        }
    }
}
