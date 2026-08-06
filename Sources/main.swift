import AppKit

if let previewFlagIndex = CommandLine.arguments.firstIndex(of: "--render-avatar-preview") {
    let pathIndex = previewFlagIndex + 1
    let outputPath = CommandLine.arguments.indices.contains(pathIndex)
        ? CommandLine.arguments[pathIndex]
        : "DesignConcepts/StickmanPreview/avatar-states.png"
    do {
        try StickmanAvatarPreviewRenderer.render(to: URL(fileURLWithPath: outputPath))
        print("Rendered Stickman avatar preview: \(outputPath)")
        exit(0)
    } catch {
        fputs("Failed to render Stickman avatar preview: \(error)\n", stderr)
        exit(1)
    }
}

if let previewFlagIndex = CommandLine.arguments.firstIndex(of: "--render-avatar-animation-preview") {
    let pathIndex = previewFlagIndex + 1
    let outputPath = CommandLine.arguments.indices.contains(pathIndex)
        ? CommandLine.arguments[pathIndex]
        : "DesignConcepts/StickmanPreview/avatar-states.gif"
    do {
        try StickmanAvatarPreviewRenderer.renderAnimation(to: URL(fileURLWithPath: outputPath))
        print("Rendered Stickman avatar animation preview: \(outputPath)")
        exit(0)
    } catch {
        fputs("Failed to render Stickman avatar animation preview: \(error)\n", stderr)
        exit(1)
    }
}

if let previewFlagIndex = CommandLine.arguments.firstIndex(of: "--render-window-preview") {
    let pathIndex = previewFlagIndex + 1
    let outputPath = CommandLine.arguments.indices.contains(pathIndex)
        ? CommandLine.arguments[pathIndex]
        : "DesignConcepts/StickmanPreview/window-preview.png"
    do {
        try StickmanWindowPreviewRenderer.render(to: URL(fileURLWithPath: outputPath))
        print("Rendered Stickman window preview: \(outputPath)")
        exit(0)
    } catch {
        fputs("Failed to render Stickman window preview: \(error)\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--check-preview-artifacts") {
    let rootPath = ProcessInfo.processInfo.environment["STICKMAN_PROJECT_DIR"]
        ?? FileManager.default.currentDirectoryPath
    do {
        try StickmanPreviewArtifactQA.run(root: URL(fileURLWithPath: rootPath))
        print("Stickman preview artifacts passed QA.")
        exit(0)
    } catch {
        fputs("Stickman preview artifact QA failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if let previewFlagIndex = CommandLine.arguments.firstIndex(of: "--render-reference-comparison") {
    let pathIndex = previewFlagIndex + 1
    let outputPath = CommandLine.arguments.indices.contains(pathIndex)
        ? CommandLine.arguments[pathIndex]
        : "DesignConcepts/StickmanPreview/reference-comparison.png"
    let rootPath = ProcessInfo.processInfo.environment["STICKMAN_PROJECT_DIR"]
        ?? FileManager.default.currentDirectoryPath
    do {
        try StickmanReferenceComparisonRenderer.render(
            root: URL(fileURLWithPath: rootPath),
            to: URL(fileURLWithPath: outputPath)
        )
        print("Rendered Stickman reference comparison: \(outputPath)")
        exit(0)
    } catch {
        fputs("Failed to render Stickman reference comparison: \(error)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
