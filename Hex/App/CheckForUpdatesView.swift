import AppKit
import Combine
import ComposableArchitecture
import Inject
import Sparkle
import SwiftUI

@Observable
@MainActor
final class CheckForUpdatesViewModel {
	static let shared = CheckForUpdatesViewModel()

	// No Sparkle connection until this fork has its own feed and signing key.
	private let controller: SPUStandardUpdaterController?
	private var anyCancellable: AnyCancellable?
	var canCheckForUpdates = true

	init() {
		if let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
		   URL(string: feed)?.scheme == "https",
		   let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
		   !key.isEmpty {
			let controller = SPUStandardUpdaterController(
				startingUpdater: true,
				updaterDelegate: nil,
				userDriverDelegate: nil
			)
			self.controller = controller
			anyCancellable = controller.updater.publisher(for: \.canCheckForUpdates)
				.sink { [weak self] in self?.canCheckForUpdates = $0 }
		} else {
			controller = nil
		}
	}

	func checkForUpdates() {
		if let controller {
			controller.updater.checkForUpdates()
		} else {
			NSWorkspace.shared.open(URL(string: "https://github.com/salishdev/Hex/releases")!)
		}
	}
}

struct CheckForUpdatesView: View {
	@State var viewModel = CheckForUpdatesViewModel.shared
	@ObserveInjection var inject

	var body: some View {
		Button("Check for Updates…", action: viewModel.checkForUpdates)
			.disabled(!viewModel.canCheckForUpdates)
			.enableInjection()
	}
}
