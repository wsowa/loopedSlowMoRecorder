/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Implements the view controller for the camera interface.
*/

import UIKit
import AVFoundation
import VideoToolbox
import Photos

class CameraViewController: UIViewController {
    // MARK: View Controller Life Cycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        UIDevice.current.isBatteryMonitoringEnabled = true
        UIApplication.shared.isIdleTimerDisabled = true

        // Disable UI. Enable the UI later, if and only if the session starts running.
        recordButton.isEnabled = false
        
        // Set up the video preview view.
        previewView.session = session
        /*
         Check video authorization status. Video access is required and audio
         access is optional. If the user denies audio access, AVCam won't
         record audio during movie recording.
         */
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera.
            break
            
        case .notDetermined:
            /*
             The user has not yet been presented with the option to grant
             video access. We suspend the session queue to delay session
             setup until the access request has completed.
             
             Note that audio access will be implicitly requested when we
             create an AVCaptureDeviceInput for audio during session setup.
             */
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted {
                    self.setupResult = .notAuthorized
                }
                self.sessionQueue.resume()
            })
            
        default:
            // The user has previously denied access.
            setupResult = .notAuthorized
        }
        
        /*
         Setup the capture session.
         In general, it is not safe to mutate an AVCaptureSession or any of its
         inputs, outputs, or connections from multiple threads at the same time.
         
         Don't perform these tasks on the main queue because
         AVCaptureSession.startRunning() is a blocking call, which can
         take a long time. We dispatch session setup to the sessionQueue, so
         that the main queue isn't blocked, which keeps the UI responsive.
         */
        sessionQueue.async {
            self.configureSession()
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        sessionQueue.async {
            switch self.setupResult {
            case .success:
                // Only setup observers and start the session running if setup succeeded.
                self.addObservers()
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning
                
            case .notAuthorized:
                DispatchQueue.main.async {
                    let changePrivacySetting = "AVCam doesn't have permission to use the camera, please change privacy settings"
                    let message = NSLocalizedString(changePrivacySetting, comment: "Alert message when the user has denied access to the camera")
                    let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: .alert)
                    
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                            style: .cancel,
                                                            handler: nil))
                    
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
                                                            style: .`default`,
                                                            handler: { _ in
                                                                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
                                                                                          options: [:],
                                                                                          completionHandler: nil)
                    }))
                    
                    self.present(alertController, animated: true, completion: nil)
                }
                
            case .configurationFailed:
                DispatchQueue.main.async {
                    let alertMsg = "Alert message when something goes wrong during capture session configuration"
                    let message = NSLocalizedString("Unable to capture media", comment: alertMsg)
                    let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: .alert)
                    
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                            style: .cancel,
                                                            handler: nil))
                    
                    self.present(alertController, animated: true, completion: nil)
                }
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        sessionQueue.async {
            if self.setupResult == .success {
                self.session.stopRunning()
                self.isSessionRunning = self.session.isRunning
                self.removeObservers()
            }
        }
        
        super.viewWillDisappear(animated)
    }
    
    override var shouldAutorotate: Bool {
        // Disable autorotation of the interface when recording is in progress.
        return isRecording
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .all
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        
        if let videoPreviewLayerConnection = previewView.videoPreviewLayer.connection {
            let deviceOrientation = UIDevice.current.orientation
            guard let newVideoOrientation = AVCaptureVideoOrientation(deviceOrientation: deviceOrientation),
                deviceOrientation.isPortrait || deviceOrientation.isLandscape else {
                    return
            }
            
            videoPreviewLayerConnection.videoOrientation = newVideoOrientation
        }
    }
    
    // MARK: Session Management
    
    private enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }
    private let session = AVCaptureSession()
    private var isSessionRunning = false
    
    private let sessionQueue = DispatchQueue(label: "session queue") // Communicate with the session and other session objects on this queue.
    
    private var setupResult: SessionSetupResult = .success
    
    private var audioDataOutput: AVCaptureAudioDataOutput!
    private var videoDataOutput: AVCaptureVideoDataOutput!
    
    @objc dynamic var videoDeviceInput: AVCaptureDeviceInput!
    
    @IBOutlet private weak var previewView: PreviewView!
    
    // Call this on the session queue.
    fileprivate func setFormat() {
        var bestFormat: AVCaptureDevice.Format?
        var bestFramerate: AVFrameRateRange?
        let videoDevice = self.videoDeviceInput.device
        
        for format in videoDevice.formats {
            for framerate in format.videoSupportedFrameRateRanges {
                if (framerate.maxFrameRate > bestFramerate?.maxFrameRate ?? 0.0) || ((framerate.maxFrameRate == bestFramerate?.maxFrameRate ?? 0.0) &&
                    (format.highResolutionStillImageDimensions.height > bestFormat?.highResolutionStillImageDimensions.height ?? 0)) {
                    bestFormat = format
                    bestFramerate = framerate
                }
            }
        }
        do {
            try videoDevice.lockForConfiguration()
        } catch {
            print("Could not lock device for configuration (my code): \(error)")
        }
        videoDevice.activeFormat = bestFormat!
        videoDevice.activeVideoMaxFrameDuration = bestFramerate!.minFrameDuration
        videoDevice.activeVideoMinFrameDuration = bestFramerate!.minFrameDuration
        videoDevice.unlockForConfiguration()
        print(bestFormat!)
    }
    
    /// - Tag: ConfigureSession
    private func configureSession() {
        if setupResult != .success {
            return
        }
        
        session.beginConfiguration()
        
        /*
         We do not create an AVCaptureMovieFileOutput when setting up the session because
         Live Photo is not supported when AVCaptureMovieFileOutput is added to the session.
         */
        session.sessionPreset = .high
        
        // Add video input.
        do {
            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                print("Default video device is unavailable.")
                setupResult = .configurationFailed
                session.commitConfiguration()
                return
            }
            
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
                
                DispatchQueue.main.async {
                    /*
                     Dispatch video streaming to the main queue because AVCaptureVideoPreviewLayer is the backing layer for PreviewView.
                     You can manipulate UIView only on the main thread.
                     Note: As an exception to the above rule, it is not necessary to serialize video orientation changes
                     on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.
                     
                     Use the status bar orientation as the initial video orientation. Subsequent orientation changes are
                     handled by CameraViewController.viewWillTransition(to:with:).
                     */
                    let statusBarOrientation = UIApplication.shared.statusBarOrientation
                    var initialVideoOrientation: AVCaptureVideoOrientation = .portrait
                    if statusBarOrientation != .unknown {
                        if let videoOrientation = AVCaptureVideoOrientation(interfaceOrientation: statusBarOrientation) {
                            initialVideoOrientation = videoOrientation
                        }
                    }
                    
                    self.previewView.videoPreviewLayer.connection?.videoOrientation = initialVideoOrientation
                }
            } else {
                print("Couldn't add video device input to the session.")
                setupResult = .configurationFailed
                session.commitConfiguration()
                return
            }
        } catch {
            print("Couldn't create video device input: \(error)")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        
        // Add audio input.
        do {
            let audioDevice = AVCaptureDevice.default(for: .audio)
            let audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice!)
            
            if session.canAddInput(audioDeviceInput) {
                session.addInput(audioDeviceInput)
            } else {
                print("Could not add audio device input to the session")
            }
        } catch {
            print("Could not create audio device input: \(error)")
        }
        
        let videoDataOutput = AVCaptureVideoDataOutput()

        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            session.sessionPreset = .high
            
            setFormat()
            
            if let connection = videoDataOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            }
            
            print(videoDataOutput.availableVideoPixelFormatTypes)
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ,
            ]
            videoDataOutput.alwaysDiscardsLateVideoFrames = false
            videoDataOutput.setSampleBufferDelegate(self, queue: sessionQueue)

            self.videoDataOutput = videoDataOutput
            
            let audioDataOutput = AVCaptureAudioDataOutput()
            if session.canAddOutput(audioDataOutput) {
                audioDataOutput.setSampleBufferDelegate(self, queue: sessionQueue)
                session.addOutput(audioDataOutput)
            } else {
                print("zonk2")
            }
            self.audioDataOutput = audioDataOutput
            
            DispatchQueue.main.async {
                self.recordButton.isEnabled = true
            }
        }
        self.session.commitConfiguration()
    }
    
    @IBAction private func resumeInterruptedSession(_ resumeButton: UIButton) {
        sessionQueue.async {
            /*
             The session might fail to start running, e.g., if a phone or FaceTime call is still
             using audio or video. A failure to start the session running will be communicated via
             a session runtime error notification. To avoid repeatedly failing to start the session
             running, we only try to restart the session running in the session runtime error handler
             if we aren't trying to resume the session running.
             */
            self.session.startRunning()
            self.isSessionRunning = self.session.isRunning
            if !self.session.isRunning {
                DispatchQueue.main.async {
                    let message = NSLocalizedString("Unable to resume", comment: "Alert message when unable to resume the session running")
                    let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: .alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil)
                    alertController.addAction(cancelAction)
                    self.present(alertController, animated: true, completion: nil)
                }
            } else {
                DispatchQueue.main.async {
                    self.resumeButton.isHidden = true
                }
            }
        }
    }
    
    // MARK: Device Configuration
    
    @IBOutlet private weak var cameraUnavailableLabel: UILabel!
    
    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera],
                                                                               mediaType: .video, position: .unspecified)
    
    @IBAction private func focusAndExposeTap(_ gestureRecognizer: UITapGestureRecognizer) {
        let devicePoint = previewView.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: gestureRecognizer.location(in: gestureRecognizer.view))
        focus(with: .autoFocus, exposureMode: .autoExpose, at: devicePoint, monitorSubjectAreaChange: true)
    }
    
    private func focus(with focusMode: AVCaptureDevice.FocusMode,
                       exposureMode: AVCaptureDevice.ExposureMode,
                       at devicePoint: CGPoint,
                       monitorSubjectAreaChange: Bool) {
        
        sessionQueue.async {
            let device = self.videoDeviceInput.device
            do {
                try device.lockForConfiguration()
                
                /*
                 Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
                 Call set(Focus/Exposure)Mode() to apply the new point of interest.
                 */
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = focusMode
                }
                
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = exposureMode
                }
                
                device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                device.unlockForConfiguration()
            } catch {
                print("Could not lock device for configuration: \(error)")
            }
        }
    }
    
    // MARK: Recording Movies
    
    private var backgroundRecordingID: UIBackgroundTaskIdentifier?
    
    @IBOutlet private weak var recordButton: UIButton!
    
    @IBOutlet private weak var resumeButton: UIButton!
    
    var isRecording: Bool = false
    var switchOverTimer: Timer? = nil
    var videoWriter: [AVAssetWriter?] = [nil, nil]
    var videoWriterInput: [AVAssetWriterInput?] = [nil, nil]
    var audioWriterInput: [AVAssetWriterInput?] = [nil, nil]
    var videoUrl: [URL?] = [nil, nil]

    fileprivate var sessionAtSourceTime: [CMTime?] = [nil, nil]

    fileprivate func canWrite(i: Int) -> Bool {
        return isRecording
            && videoWriter[i] != nil
            && videoWriter[i]?.status == .writing
    }
    fileprivate func setupWriter(i: Int) {
        do {
            let outputFileName = NSUUID().uuidString
            let outputFilePath = (NSTemporaryDirectory() as NSString).appendingPathComponent((outputFileName as NSString).appendingPathExtension("mov")!)
            let url = URL(fileURLWithPath: outputFilePath)
            print ("settting up writer to \(url.lastPathComponent)")

            let videoWriter = try AVAssetWriter(outputURL: url, fileType: AVFileType.mov)
        
            let videoWriterInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: self.videoDeviceInput.device.activeFormat.highResolutionStillImageDimensions.width,
                AVVideoHeightKey: self.videoDeviceInput.device.activeFormat.highResolutionStillImageDimensions.height,
                AVVideoCompressionPropertiesKey: [
//                    AVVideoAverageBitRateKey: 1280*720*11.4
                    AVVideoAverageBitRateKey: 1920*1080*11.4
                ],
                ])
            videoWriterInput.expectsMediaDataInRealTime = true //Make sure we are exporting data at realtime
            if videoWriter.canAdd(videoWriterInput) {
                videoWriter.add(videoWriterInput)
            }
            
            //Add audio input
            let audioWriterInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 64000,
                ])
            audioWriterInput.expectsMediaDataInRealTime = true
            if videoWriter.canAdd(audioWriterInput) {
                videoWriter.add(audioWriterInput)
            }
            
            videoWriter.startWriting() //Means ready to write down the file
            
            self.sessionAtSourceTime[i] = nil
            self.videoWriter[i] = videoWriter
            self.videoWriterInput[i] = videoWriterInput
            self.audioWriterInput[i] = audioWriterInput
            self.videoUrl[i] = url
        }
        catch let error {
            debugPrint(error.localizedDescription)
        }
    }
    fileprivate func switchOver() {
        print ("switchOver")
        let current = n
        let next = (n+1) % 2
        let prevUrl: URL! = self.videoUrl[next] ?? nil
        
        self.setupWriter(i: next)
        self.n = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.finishFileRecording(i: current!)
            if prevUrl != nil { self.deleteFile(url: prevUrl!) }
        }
        
    }
    fileprivate func startRecording() {
        print ("starting")

//        if UIDevice.current.isMultitaskingSupported {
//            self.backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
//        }
        
        self.setupWriter(i: n)
        self.isRecording = true

        DispatchQueue.main.async {
            self.recordButton.isEnabled = true
            self.recordButton.setImage(#imageLiteral(resourceName: "CaptureStop"), for: [])
            self.switchOverTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) {_ in
                self.switchOver()
            }
        }
    }
    fileprivate func deleteFile(url: URL) {
        print ("about to delete \(url.lastPathComponent)")

        do {
            try FileManager.default.removeItem(at: url)
            print ("deleted \(url.lastPathComponent)")
        } catch {
            print("Could not remove file at url: \(url.lastPathComponent)")
        }
    }
    fileprivate func storeVideo(url: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }) { completed, error in
            if completed {
                print("Video \(url.lastPathComponent) moved to camera roll")
            }
            
            if error != nil {
                print(error.debugDescription)
                print(error)
                print ("ERROR:::Cannot move the video \(url.lastPathComponent) to camera roll, error: \(error!.localizedDescription)")
                self.deleteFile(url: url)
            }
        }
    }
    
    func finishFileRecording(i: Int) {
        if self.sessionAtSourceTime[i] != nil {
            self.sessionAtSourceTime[i] = nil
            let url = self.videoUrl[i]!
            self.videoWriterInput[i]!.markAsFinished()
            print("wrriting \(url.lastPathComponent)")
            self.videoWriter[i]!.finishWriting {
                if self.videoWriter[i]!.status == AVAssetWriter.Status.completed {
                    print("wrriting completed for \(url.lastPathComponent)")
                } else {
                    let status = self.videoWriter[i]!.status.rawValue
                    let error = self.videoWriter[i]!.error
                    print("WARN:::writing failed for \(url.lastPathComponent), stauts: \(status), error: \(String(describing: error))")
                    self.deleteFile(url: url)
                }
            }
        }
    }
    fileprivate func stopRecording() {
        print ("stoping")
        self.isRecording = false
        self.switchOverTimer?.invalidate()
        self.switchOverTimer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.finishFileRecording(i: 0)
            self.finishFileRecording(i: 1)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if self.videoUrl[0] != nil {self.storeVideo(url: self.videoUrl[0]!)}
                if self.videoUrl[1] != nil {self.storeVideo(url: self.videoUrl[1]!)}
                self.videoUrl[0] = nil
                self.videoUrl[1] = nil

                self.recordButton.isEnabled = true
                self.recordButton.setImage(#imageLiteral(resourceName: "CaptureVideo"), for: [])
            }
        }
    }
    
    @IBAction private func toggleMovieRecording(_ recordButton: UIButton) {
        /*
         Disable the Camera button until recording finishes, and disable
         the Record button until recording starts or finishes.
         
         See the AVCaptureFileOutputRecordingDelegate methods.
         */
        recordButton.isEnabled = false
        
        DispatchQueue.main.async {
            if !self.isRecording {
                self.startRecording()
            } else {
                self.stopRecording()
            }
        }
    }
    /*
    /// - Tag: DidStartRecording
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        // Enable the Record button to let the user stop recording.
        print("recording to \(fileURL)")
        DispatchQueue.main.async {
            self.recordButton.isEnabled = true
            self.recordButton.setImage(#imageLiteral(resourceName: "CaptureStop"), for: [])
        }
    }
    
    /// - Tag: DidFinishRecording
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        
        // Note: Since we use a unique file path for each recording, a new recording won't overwrite a recording mid-save.
        func cleanup() {
            let path = outputFileURL.path
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    print("Could not remove file at url: \(outputFileURL)")
                }
            }
            
            if let currentBackgroundRecordingID = backgroundRecordingID {
                backgroundRecordingID = UIBackgroundTaskIdentifier.invalid

                if currentBackgroundRecordingID != UIBackgroundTaskIdentifier.invalid {
                    UIApplication.shared.endBackgroundTask(currentBackgroundRecordingID)
                }
            }
        }
        
        var success = true
        
        if error != nil {
            print("Movie file finishing error: \(String(describing: error))")
            success = (((error! as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as AnyObject).boolValue)!
        }
        
        if success {
            // Check authorization status.
            PHPhotoLibrary.requestAuthorization { status in
                if status == .authorized {
                    // Save the movie file to the photo library and cleanup.
                    PHPhotoLibrary.shared().performChanges({
                        let options = PHAssetResourceCreationOptions()
                        options.shouldMoveFile = true
                        let creationRequest = PHAssetCreationRequest.forAsset()
                        creationRequest.addResource(with: .video, fileURL: outputFileURL, options: options)
                    }, completionHandler: { success, error in
                        if !success {
                            print("AVCam couldn't save the movie to your photo library: \(String(describing: error))")
                        }
                        cleanup()
                    }
                    )
                } else {
                    cleanup()
                }
            }
        } else {
            cleanup()
        }
        
        if success {
            self.isRecording = true
            self.startRecording()
        }
        
        // Enable the Camera and Record buttons to let the user switch camera and start another recording.
        DispatchQueue.main.async {
            // Only enable the ability to change camera if the device has more than one camera.
            self.recordButton.isEnabled = true
            self.recordButton.setImage(#imageLiteral(resourceName: "CaptureVideo"), for: [])
        }
    }
    */
    // MARK: KVO and Notifications
    
    private var keyValueObservations = [NSKeyValueObservation]()
    /// - Tag: ObserveInterruption
    private func addObservers() {
        let keyValueObservation = session.observe(\.isRunning, options: .new) { _, change in
            guard let isSessionRunning = change.newValue else { return }
            
            DispatchQueue.main.async {
                self.recordButton.isEnabled = isSessionRunning && self.videoDataOutput != nil
            }
        }
        keyValueObservations.append(keyValueObservation)
        
        let systemPressureStateObservation = observe(\.videoDeviceInput.device.systemPressureState, options: .new) { _, change in
            guard let systemPressureState = change.newValue else { return }
            self.setRecommendedFrameRateRangeForPressureState(systemPressureState: systemPressureState)
        }
        keyValueObservations.append(systemPressureStateObservation)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(subjectAreaDidChange),
                                               name: .AVCaptureDeviceSubjectAreaDidChange,
                                               object: videoDeviceInput.device)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionRuntimeError),
                                               name: .AVCaptureSessionRuntimeError,
                                               object: session)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(batteryStateDidChange),
                                               name: UIDevice.batteryStateDidChangeNotification, object: nil)

        /*
         A session can only run when the app is full screen. It will be interrupted
         in a multi-app layout, introduced in iOS 9, see also the documentation of
         AVCaptureSessionInterruptionReason. Add observers to handle these session
         interruptions and show a preview is paused message. See the documentation
         of AVCaptureSessionWasInterruptedNotification for other interruption reasons.
         */
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionWasInterrupted),
                                               name: .AVCaptureSessionWasInterrupted,
                                               object: session)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sessionInterruptionEnded),
                                               name: .AVCaptureSessionInterruptionEnded,
                                               object: session)
    }
    
    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
        
        for keyValueObservation in keyValueObservations {
            keyValueObservation.invalidate()
        }
        keyValueObservations.removeAll()
    }
    
    @objc
    func batteryStateDidChange(_ notification: Notification) {
        switch UIDevice.current.batteryState {
        case .unplugged:
            print("Charger unplugged!")
            if (isRecording) {
                DispatchQueue.main.asyncAfter(deadline: .now()+3) {
                    self.stopRecording()
                }
            }
            default: break
        }
    }
    
    @objc
    func subjectAreaDidChange(notification: NSNotification) {
        let devicePoint = CGPoint(x: 0.5, y: 0.5)
        focus(with: .continuousAutoFocus, exposureMode: .continuousAutoExposure, at: devicePoint, monitorSubjectAreaChange: false)
    }
    
    /// - Tag: HandleRuntimeError
    @objc
    func sessionRuntimeError(notification: NSNotification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        
        print("Capture session runtime error: \(error)")
        // If media services were reset, and the last start succeeded, restart the session.
        if error.code == .mediaServicesWereReset {
            sessionQueue.async {
                if self.isSessionRunning {
                    self.session.startRunning()
                    self.isSessionRunning = self.session.isRunning
                } else {
                    DispatchQueue.main.async {
                        self.resumeButton.isHidden = false
                    }
                }
            }
        } else {
            resumeButton.isHidden = false
        }
    }
    
    /// - Tag: HandleSystemPressure
    private func setRecommendedFrameRateRangeForPressureState(systemPressureState: AVCaptureDevice.SystemPressureState) {
        /*
         The frame rates used here are for demonstrative purposes only for this app.
         Your frame rate throttling may be different depending on your app's camera configuration.
         */
        let pressureLevel = systemPressureState.level
        if pressureLevel == .serious || pressureLevel == .critical {
            print("WARNING: Reached elevated system pressure level: \(pressureLevel).")
        } else if pressureLevel == .shutdown {
            print("Session stopped running due to shutdown system pressure level.")
        }
    }
    
    /// - Tag: HandleInterruption
    @objc
    func sessionWasInterrupted(notification: NSNotification) {
        /*
         In some scenarios we want to enable the user to resume the session running.
         For example, if music playback is initiated via control center while
         using AVCam, then the user can let AVCam resume
         the session running, which will stop music playback. Note that stopping
         music playback in control center will not automatically resume the session
         running. Also note that it is not always possible to resume, see `resumeInterruptedSession(_:)`.
         */
        if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
            let reasonIntegerValue = userInfoValue.integerValue,
            let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
            print("Capture session was interrupted with reason \(reason)")
            
            var showResumeButton = false
            if reason == .audioDeviceInUseByAnotherClient || reason == .videoDeviceInUseByAnotherClient {
                showResumeButton = true
            } else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
                // Fade-in a label to inform the user that the camera is unavailable.
                cameraUnavailableLabel.alpha = 0
                cameraUnavailableLabel.isHidden = false
                UIView.animate(withDuration: 0.25) {
                    self.cameraUnavailableLabel.alpha = 1
                }
            } else if reason == .videoDeviceNotAvailableDueToSystemPressure {
                print("Session stopped running due to shutdown system pressure level.")
            }
            if showResumeButton {
                // Fade-in a button to enable the user to try to resume the session running.
                resumeButton.alpha = 0
                resumeButton.isHidden = false
                UIView.animate(withDuration: 0.25) {
                    self.resumeButton.alpha = 1
                }
            }
        }
    }
    
    @objc
    func sessionInterruptionEnded(notification: NSNotification) {
        print("Capture session interruption ended")
        
        if !resumeButton.isHidden {
            UIView.animate(withDuration: 0.25,
                           animations: {
                            self.resumeButton.alpha = 0
            }, completion: { _ in
                self.resumeButton.isHidden = true
            })
        }
        if !cameraUnavailableLabel.isHidden {
            UIView.animate(withDuration: 0.25,
                           animations: {
                            self.cameraUnavailableLabel.alpha = 0
            }, completion: { _ in
                self.cameraUnavailableLabel.isHidden = true
            }
            )
        }
    }
    var d: Int! = 0
    var f: Int! = 0
    var wf: Int! = 0
    var n: Int! = 0
}

extension AVCaptureVideoOrientation {
    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeRight
        case .landscapeRight: self = .landscapeLeft
        default: return nil
        }
    }
    
    init?(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: return nil
        }
    }
}

extension AVCaptureDevice.DiscoverySession {
    var uniqueDevicePositionsCount: Int {
        var uniqueDevicePositions: [AVCaptureDevice.Position] = []
        
        for device in devices {
            if !uniqueDevicePositions.contains(device.position) {
                uniqueDevicePositions.append(device.position)
            }
        }
        
        return uniqueDevicePositions.count
    }

}


extension CameraViewController:
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    //There is only one same method for both of these delegates
    fileprivate func write(_ didOutput: CMSampleBuffer, _ captureOutput: AVCaptureOutput, i: Int) {
        let writable = canWrite(i: i)
        
        if writable,
            sessionAtSourceTime[i] == nil {
            //Start writing
            sessionAtSourceTime[i] = CMSampleBufferGetPresentationTimeStamp(didOutput)
            videoWriter[i]?.startSession(atSourceTime: sessionAtSourceTime[i]!)
        }
        
        if writable, captureOutput == videoDataOutput {
            
            if videoWriterInput[i]!.isReadyForMoreMediaData {
                wf+=1
                videoWriterInput[i]!.append(didOutput)
            }
        } else if writable, captureOutput == audioDataOutput, audioWriterInput[i]!.isReadyForMoreMediaData {
            wf+=1
            audioWriterInput[i]!.append(didOutput)
        }
    }

    func captureOutput(_ captureOutput: AVCaptureOutput, didOutput: CMSampleBuffer, from: AVCaptureConnection) {
        f+=1
        guard CMSampleBufferDataIsReady(didOutput) else { return }
        
        write(didOutput, captureOutput, i: n)

        if ((f+d) % 1000 == 0) {print ("\(f+d)/\(d+0)/\(wf+0)")}
    }
    
    func captureOutput(_ captureOutput: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        
        d+=1
    }
    
}
