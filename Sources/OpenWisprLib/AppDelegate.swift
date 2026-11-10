import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController!
    var hotkeyManagers: [HotkeyManager] = []
    var recorder: AudioRecorder!
    var transcriber: Transcriber!
    var inserter: TextInserter!
    var config: Config!
    var recordingLifecycle = RecordingLifecycle()
    private let recordingSoundFeedback = RecordingSoundFeedback()
    private let jarvis = JarvisClient()
    private let jarvisSpeaker = JarvisSpeaker()
    private var jarvisMode = false
    private var jarvisPresenter = JarvisPresenter()
    private var jarvisHideWork: DispatchWorkItem?
    private var learning = PronunciationLearning()
    var currentRecordingURL: URL?
    private var sleepWakeObservers: [NSObjectProtocol] = []
    private var accessibilityPollTimer: Timer?
    var isReady = false
    public var lastTranscription: String?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        statusBar.onIdle = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.isScreenFreeForJarvis else { return }
                self.render(self.jarvisPresenter.screenFreed())
            }
        }
        setupJarvisAnnouncements()
        recorder = AudioRecorder()
        registerSleepWakeObservers()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setup()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        accessibilityPollTimer?.invalidate()
        recorder?.teardown()
        unregisterSleepWakeObservers()
    }

    private func setup() {
        do {
            try setupInner()
        } catch {
            print("Fatal setup error: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.statusBar.state = .error(error.localizedDescription)
                self?.statusBar.updateDownloadProgress(nil)
            }
        }
    }

    private func setupInner() throws {
        config = Config.load()
        inserter = TextInserter()
        migrateAudioDeviceUIDIfNeeded()
        recorder.preferredDeviceID = AudioDeviceManager.resolveConfiguredDeviceID(
            uid: config.audioInputDeviceUID,
            legacyID: config.audioInputDeviceID
        )
        recorder.voiceProcessingEnabled = config.isVoiceProcessingEnabled
        if Config.effectiveMaxRecordings(config.maxRecordings) == 0 {
            RecordingStore.deleteAllRecordings()
        }
        transcriber = makeTranscriber(for: config)

        DispatchQueue.main.async {
            self.statusBar.reprocessHandler = { [weak self] url in
                self?.reprocess(audioURL: url)
            }
            self.statusBar.onConfigChange = { [weak self] newConfig in
                self?.applyConfigChange(newConfig)
            }
            self.statusBar.buildMenu()
        }

        if Transcriber.findWhisperBinary() == nil {
            print("Error: whisper-cpp not found. Install it with: brew install whisper-cpp")
            return
        }

        let didUpgrade = Permissions.didUpgrade()
        if Permissions.shouldResetAccessibility(afterUpgrade: didUpgrade, isTrusted: AXIsProcessTrusted()) {
            print("Accessibility: version changed and permission is not granted; resetting stale entry...")
            if Permissions.resetAccessibility() {
                Permissions.recordCurrentVersion()
                Thread.sleep(forTimeInterval: 1)
            } else {
                print("Accessibility: reset failed; toggle OpenWispr OFF, then ON in System Settings")
            }
        }

        Permissions.ensureMicrophone()

        if !AXIsProcessTrusted() {
            print("Accessibility: not granted")
            print("Waiting for Accessibility permission...")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.statusBar.state = .waitingForPermission
                self.statusBar.buildMenu()
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
                self.startAccessibilityPolling()
            }
            return
        }

        print("Accessibility: granted")
        Permissions.recordCurrentVersion()
        try finishSetup()
    }

    private func startAccessibilityPolling() {
        guard accessibilityPollTimer == nil else { return }
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.resumeWhenAccessibilityGranted()
        }
        resumeWhenAccessibilityGranted()
    }

    private func resumeWhenAccessibilityGranted() {
        guard AXIsProcessTrusted() else { return }
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        print("Accessibility: granted")
        Permissions.recordCurrentVersion()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.finishSetup()
            } catch {
                print("Fatal setup error: \(error.localizedDescription)")
            }
        }
    }

    private func finishSetup() throws {
        if !Transcriber.modelExists(modelSize: config.modelSize) {
            DispatchQueue.main.async {
                self.statusBar.state = .downloading
                self.statusBar.updateDownloadProgress("Downloading \(self.config.modelSize) model...")
            }
            print("Downloading \(config.modelSize) model...")
            try ModelDownloader.download(modelSize: config.modelSize) { [weak self] percent in
                DispatchQueue.main.async {
                    let pct = Int(percent)
                    self?.statusBar.updateDownloadProgress("Downloading \(self?.config.modelSize ?? "") model... \(pct)%", percent: percent)
                }
            }
            DispatchQueue.main.async {
                self.statusBar.updateDownloadProgress(nil)
            }
        }

        if let modelPath = Transcriber.findModel(modelSize: config.modelSize) {
            let modelURL = URL(fileURLWithPath: modelPath)
            if !ModelDownloader.isValidGGMLFile(at: modelURL) {
                let msg = "Model file is corrupted. Re-download with: open-wispr download-model \(config.modelSize)"
                print("Error: \(msg)")
                DispatchQueue.main.async {
                    self.statusBar.state = .error(msg)
                    self.statusBar.buildMenu()
                }
                return
            }
        }

        if config.isVADEnabled && Transcriber.findVADModel() == nil {
            DispatchQueue.main.async {
                self.statusBar.state = .downloading
                self.statusBar.updateDownloadProgress("Downloading voice activity model...")
            }
            try ModelDownloader.downloadVAD { [weak self] percent in
                DispatchQueue.main.async {
                    self?.statusBar.updateDownloadProgress("Downloading voice activity model... \(Int(percent))%", percent: percent)
                }
            }
            DispatchQueue.main.async { self.statusBar.updateDownloadProgress(nil) }
        }

        DispatchQueue.main.async { [weak self] in
            self?.startListening()
        }
    }

    private func startListening() {
        for m in hotkeyManagers { m.stop() }
        hotkeyManagers = []
        for hk in config.hotkeys {
            let manager = HotkeyManager(
                keyCode: hk.keyCode,
                modifiers: hk.modifierFlags
            )
            manager.start(
                onKeyDown: { [weak self] in
                    self?.handleKeyDown()
                },
                onKeyUp: { [weak self] in
                    self?.handleKeyUp()
                }
            )
            hotkeyManagers.append(manager)
        }

        isReady = true
        statusBar.state = .idle
        statusBar.buildMenu()

        let hotkeyDesc = config.hotkeySummary()
        print("open-wispr v\(OpenWispr.version)")
        print("Hotkey: \(hotkeyDesc)")
        print("Model: \(config.modelSize)")
        print("Ready.")
        recorder.prepare()
    }

    public func reloadConfig() {
        let newConfig = Config.load()
        applyConfigChange(newConfig)
    }

    /// Configs written by older versions store only the numeric AudioDeviceID,
    /// which is not stable across reboots or device replugs. If that ID still
    /// refers to a device, persist its UID so the selection survives.
    private func migrateAudioDeviceUIDIfNeeded() {
        guard config.audioInputDeviceUID == nil,
              let legacyID = config.audioInputDeviceID,
              let uid = AudioDeviceManager.getDeviceUID(deviceID: legacyID) else { return }
        config.audioInputDeviceUID = uid
        try? config.save()
    }

    func applyConfigChange(_ newConfig: Config) {
        guard isReady else { return }
        let wasDownloading: Bool
        if case .downloading = statusBar.state { wasDownloading = true } else { wasDownloading = false }
        let newDeviceID = AudioDeviceManager.resolveConfiguredDeviceID(
            uid: newConfig.audioInputDeviceUID,
            legacyID: newConfig.audioInputDeviceID
        )
        config = newConfig
        recorder.preferredDeviceID = newDeviceID
        recorder.voiceProcessingEnabled = config.isVoiceProcessingEnabled
        recorder.prepare()
        transcriber = makeTranscriber(for: config)
        inserter = TextInserter()

        for m in hotkeyManagers { m.stop() }
        hotkeyManagers = []
        for hk in config.hotkeys {
            let manager = HotkeyManager(
                keyCode: hk.keyCode,
                modifiers: hk.modifierFlags
            )
            manager.start(
                onKeyDown: { [weak self] in self?.handleKeyDown() },
                onKeyUp: { [weak self] in self?.handleKeyUp() }
            )
            hotkeyManagers.append(manager)
        }

        let needsWhisperModel = !Transcriber.modelExists(modelSize: config.modelSize)
        let needsVADModel = config.isVADEnabled && Transcriber.findVADModel() == nil
        if !wasDownloading && (needsWhisperModel || needsVADModel) {
            statusBar.state = .downloading
            statusBar.updateDownloadProgress(needsWhisperModel
                ? "Downloading \(config.modelSize) model..."
                : "Downloading voice activity model...")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    if needsWhisperModel {
                        try ModelDownloader.download(modelSize: newConfig.modelSize) { percent in
                            DispatchQueue.main.async {
                                self?.statusBar.updateDownloadProgress("Downloading \(newConfig.modelSize) model... \(Int(percent))%", percent: percent)
                            }
                        }
                    }
                    if needsVADModel {
                        DispatchQueue.main.async {
                            self?.statusBar.updateDownloadProgress("Downloading voice activity model...")
                        }
                        try ModelDownloader.downloadVAD { percent in
                            DispatchQueue.main.async {
                                self?.statusBar.updateDownloadProgress("Downloading voice activity model... \(Int(percent))%", percent: percent)
                            }
                        }
                    }
                    DispatchQueue.main.async {
                        self?.statusBar.state = .idle
                        self?.statusBar.updateDownloadProgress(nil)
                    }
                } catch {
                    DispatchQueue.main.async {
                        print("Error downloading model: \(error.localizedDescription)")
                        self?.statusBar.state = .error(error.localizedDescription)
                        self?.statusBar.buildMenu()
                    }
                }
            }
        }

        statusBar.buildMenu()

        let hotkeyDesc = config.hotkeySummary()
        print("Config updated: lang=\(config.language) model=\(config.modelSize) hotkey=\(hotkeyDesc)")
    }

    private func makeTranscriber(for config: Config) -> Transcriber {
        let transcriber = Transcriber(
            modelSize: config.modelSize,
            language: config.language,
            whisperPrompt: config.whisperPrompt,
            vadEnabled: config.isVADEnabled,
            vadThreshold: config.effectiveVADThreshold
        )
        transcriber.spokenPunctuation = config.spokenPunctuation?.value ?? false
        transcriber.customDictionary = config.customDictionary ?? []
        return transcriber
    }

    private func handleKeyDown() {
        guard isReady else { return }

        let isToggle = config.toggleMode?.value ?? false

        switch recordingLifecycle.keyDown(toggleMode: isToggle) {
        case .startRecording:
            handleRecordingStart()
        case .stopRecording:
            handleRecordingStop()
        case .none, .cancelRecording, .prepareRecorder:
            break
        }
    }

    private func handleKeyUp() {
        guard isReady else { return }

        let isToggle = config.toggleMode?.value ?? false

        if recordingLifecycle.keyUp(toggleMode: isToggle) == .stopRecording {
            handleRecordingStop()
        }
    }

    private func handleRecordingStart() {
        // Option (⌥) maintenue au moment d'appuyer sur la touche = mode Jarvis.
        jarvisMode = NSEvent.modifierFlags.contains(.option)
        statusBar.jarvisMode = jarvisMode
        jarvisSpeaker.stop()
        if jarvisMode {
            // Une nouvelle question remplace la précédente ; une simple dictée la laisse tourner.
            jarvis.cancel()
            jarvisPresenter.reset()
        }
        statusBar.state = .recording
        do {
            recorder.preferredDeviceID = AudioDeviceManager.resolveConfiguredDeviceID(
                uid: config.audioInputDeviceUID,
                legacyID: config.audioInputDeviceID
            )
            let outputURL: URL
            if Config.effectiveMaxRecordings(config.maxRecordings) == 0 {
                outputURL = RecordingStore.tempRecordingURL()
            } else {
                outputURL = RecordingStore.newRecordingURL()
            }
            try recorder.startRecording(to: outputURL)
            currentRecordingURL = outputURL
            if config.isSoundFeedbackEnabled {
                recordingSoundFeedback.playStarted()
            }
        } catch {
            print("Error: \(error.localizedDescription)")
            recordingLifecycle.recordingStartFailed()
            currentRecordingURL = nil
            statusBar.state = .idle
        }
    }

    private func handleRecordingStop() {
        guard let audioURL = recorder.stopRecording() else {
            RecordingCancellation.discardTrackedPartialRecording(&currentRecordingURL)
            statusBar.state = .idle
            return
        }

        currentRecordingURL = nil
        let isJarvis = jarvisMode
        _ = learning.expireIfIdle()
        if isJarvis, learning.isRecordingTakes {
            if config.isSoundFeedbackEnabled {
                recordingSoundFeedback.playStopped()
            }
            statusBar.state = .transcribing
            // La prise est aussi transcrite : « annule » arrête l'apprentissage.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let heard = (try? self.transcriber.transcribe(audioURL: audioURL)).map(self.postProcess) ?? ""
                DispatchQueue.main.async {
                    if PronunciationAnswer.parse(heard) == .cancel {
                        self.learning.cancel()
                        if Config.effectiveMaxRecordings(self.config.maxRecordings) == 0 {
                            try? FileManager.default.removeItem(at: audioURL)
                        }
                        self.statusBar.state = .idle
                        self.showJarvis(.answer("D'accord, je laisse tomber."))
                    } else {
                        self.collectPronunciationTake(audioURL)
                    }
                }
            }
            return
        }
        statusBar.state = .transcribing
        if config.isSoundFeedbackEnabled {
            recordingSoundFeedback.playStopped()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let maxRecordings = Config.effectiveMaxRecordings(self.config.maxRecordings)
            defer {
                if maxRecordings == 0 {
                    try? FileManager.default.removeItem(at: audioURL)
                }
            }
            do {
                let raw = try self.transcriber.transcribe(audioURL: audioURL)
                let text = self.postProcess(raw)
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        self.lastTranscription = text
                        if isJarvis {
                            self.askJarvis(text)
                            return
                        }
                        if self.inserter.insert(text: text) == .copiedToClipboard {
                            self.statusBar.state = .copiedToClipboard
                            self.statusBar.buildMenu()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                if case .copiedToClipboard = self.statusBar.state {
                                    self.statusBar.state = .idle
                                    self.statusBar.buildMenu()
                                }
                            }
                            return
                        }
                    }
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            } catch {
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                DispatchQueue.main.async {
                    print("Error: \(error.localizedDescription)")
                    self.statusBar.state = .error(error.localizedDescription)
                    self.statusBar.buildMenu()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if case .error = self.statusBar.state {
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    }
                }
            }
        }
    }

    private func setupJarvisAnnouncements() {
        jarvis.canAnnounce = { [weak self] in
            guard let self = self else { return false }
            if case .idle = self.statusBar.state { return !self.jarvisSpeaker.isSpeaking }
            return false
        }
        jarvis.onAnnouncement = { [weak self] result in
            switch result {
            case .success(let answer):
                print("Jarvis tâche de fond -> \(answer)")
                JarvisNotifier.notify(JarvisSpeaker.plainText(answer))
                self?.showJarvis(.answer(answer))
            case .failure(let error):
                print("Jarvis tâche de fond : \(error.localizedDescription)")
                JarvisNotifier.notify(error.localizedDescription)
            }
        }
        jarvis.resume()
    }

    private func askJarvis(_ text: String) {
        print("Jarvis <- \(text)")
        if learning.expireIfIdle() {
            print("Apprentissage de prononciation expiré")
        }
        if learning.isConfirming, answerPronunciation(text) { return }
        // Cette transcription est la nôtre : elle ne compte pas comme une dictée en cours.
        var screenFree = isScreenFreeForJarvis
        if case .transcribing = statusBar.state { screenFree = true }
        render(jarvisPresenter.update(.thinking(nil), screenFree: screenFree))
        let onTool: (String) -> Void = { [weak self] name in
            print("Jarvis outil : \(name)")
            self?.showJarvis(.thinking(JarvisStream.toolLabel(name)))
        }
        let completion: (Result<String, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let answer):
                    let reply = answer.isEmpty ? "(réponse vide)" : answer
                    print("Jarvis -> \(reply)")
                    self?.showJarvis(.answer(reply))
                case .failure(let error):
                    print("Jarvis error: \(error.localizedDescription)")
                    self?.showJarvis(.failure("Jarvis : \(error.localizedDescription)"))
                }
            }
        }
        switch JarvisCommand.parse(text) {
        case .ask(let question):
            jarvis.ask(question, onTool: onTool, completion: completion)
        case .remember(let note):
            jarvis.remember(note, onTool: onTool, completion: completion)
        case .learnPronunciation(let word):
            learning.start(word)
            JarvisVoiceService.prepare()
            completion(.success("D'accord, j'apprends « \(word) ». Maintiens Option et dis le mot, "
                + "trois fois de suite."))
        case .newConversation:
            let reply = jarvis.newConversation()
                ? "Nouvelle conversation. La tâche de fond en cours ne sera pas annoncée."
                : "Nouvelle conversation."
            completion(.success(reply))
        }
    }

    /// Une prise ⌥ pendant l'apprentissage n'est pas transcrite : elle part au service vocal.
    private func collectPronunciationTake(_ audioURL: URL) {
        let directory = JarvisVoiceService.takesDirectory
        let take = directory.appendingPathComponent("take-\(learning.takeCount + 1).wav")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: take)
            try FileManager.default.copyItem(at: audioURL, to: take)
        } catch {
            learning.cancel()
            showJarvis(.failure("Apprentissage : prise impossible à enregistrer."))
            return
        }
        if Config.effectiveMaxRecordings(config.maxRecordings) == 0 {
            try? FileManager.default.removeItem(at: audioURL)
        }
        guard let takes = learning.addTake(take) else {
            statusBar.state = .idle
            showJarvis(.answer("Prise \(learning.takeCount) sur \(PronunciationLearning.takesNeeded)."))
            return
        }
        statusBar.state = .idle
        showJarvis(.thinking("J'écoute les prises…"))
        Task { @MainActor [weak self] in
            do {
                let phonemes = try await JarvisVoiceService.learn(takes)
                guard let self = self, let word = self.learning.word else { return }
                print("Prononciation apprise : \(word) = \(phonemes)")
                self.learning.learned(phonemes)
                self.showJarvis(.answer("Voici le mot \(word), dans une phrase. Je le garde ?"))
            } catch {
                self?.learning.cancel()
                self?.showJarvis(.failure("Apprentissage : \(error.localizedDescription)"))
            }
        }
    }

    /// Renvoie vrai si la phrase était la réponse à « Je le garde ? ».
    private func answerPronunciation(_ text: String) -> Bool {
        guard case .confirming(let word, let phonemes) = learning.phase else { return false }
        switch PronunciationAnswer.parse(text) {
        case .keep:
            learning.cancel()
            showJarvis(.thinking(nil))
            Task { @MainActor [weak self] in
                do {
                    try await JarvisVoiceService.saveWord(word, phonemes: phonemes)
                    self?.showJarvis(.answer("C'est noté, je dirai \(word) comme ça."))
                } catch {
                    self?.showJarvis(.failure("Apprentissage : \(error.localizedDescription)"))
                }
            }
        case .retry:
            learning.start(word)
            showJarvis(.answer("D'accord, on recommence. Dis le mot trois fois, avec Option."))
        case .cancel:
            learning.cancel()
            showJarvis(.answer("D'accord, je laisse tomber."))
        case .other:
            learning.cancel()
            return false
        }
        return true
    }

    /// Une dictée en cours garde la pastille : Jarvis attend qu'elle se termine.
    private func showJarvis(_ display: JarvisPresenter.Display) {
        render(jarvisPresenter.update(display, screenFree: isScreenFreeForJarvis))
    }

    private var isScreenFreeForJarvis: Bool {
        switch statusBar.state {
        case .idle, .jarvisThinking, .jarvisAnswer: return true
        default: return false
        }
    }

    private func render(_ display: JarvisPresenter.Display?) {
        guard let display = display else { return }
        jarvisHideWork?.cancel()
        switch display {
        case .thinking(let detail):
            statusBar.state = .jarvisThinking(detail)
        case .answer(let reply):
            statusBar.state = .jarvisAnswer(JarvisSpeaker.plainText(reply))
            jarvisSpeaker.speak(reply, pronunciations: learning.pendingPronunciation)
            hideJarvis(after: min(25, max(5, Double(reply.count) / 14)))
        case .failure(let message):
            statusBar.state = .error(message)
            hideJarvis(after: 5)
        }
    }

    private func hideJarvis(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            switch self.statusBar.state {
            case .jarvisAnswer, .error: self.statusBar.state = .idle
            default: break
            }
        }
        jarvisHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func postProcess(_ raw: String) -> String {
        var text = (config.spokenPunctuation?.value ?? false) ? TextPostProcessor.process(raw) : raw
        text = DictionaryPostProcessor.process(text, dictionary: config.customDictionary ?? [])
        return text
    }

    func handleSystemWillSleep() {
        recorder.teardown()
        guard recordingLifecycle.systemWillSleep() == .cancelRecording else { return }

        RecordingCancellation.discardTrackedPartialRecording(&currentRecordingURL)
        resetRecordingStatusToIdleIfNeeded()
    }

    func handleSystemDidWake() {
        guard recordingLifecycle.systemDidWake(isReady: isReady) == .prepareRecorder else { return }

        recorder.preferredDeviceID = AudioDeviceManager.resolveConfiguredDeviceID(
            uid: config.audioInputDeviceUID,
            legacyID: config.audioInputDeviceID
        )
        recorder.prepare()
    }

    private func registerSleepWakeObservers() {
        guard sleepWakeObservers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        sleepWakeObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleSystemWillSleep()
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleSystemDidWake()
            },
        ]
    }

    private func unregisterSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepWakeObservers {
            center.removeObserver(observer)
        }
        sleepWakeObservers = []
    }

    private func resetRecordingStatusToIdleIfNeeded() {
        guard case .recording = statusBar.state else { return }
        statusBar.state = .idle
        statusBar.buildMenu()
    }

    public func reprocess(audioURL: URL) {
        guard case .idle = statusBar.state else { return }

        statusBar.state = .transcribing

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let raw = try self.transcriber.transcribe(audioURL: audioURL)
                let text = self.postProcess(raw)
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        self.lastTranscription = text
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        self.statusBar.state = .copiedToClipboard
                        self.statusBar.buildMenu()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    } else {
                        self.statusBar.state = .idle
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    print("Reprocess error: \(error.localizedDescription)")
                    self.statusBar.state = .idle
                }
            }
        }
    }
}
