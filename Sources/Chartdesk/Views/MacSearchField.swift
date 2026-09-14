import AppKit
import SwiftUI

extension Notification.Name {
    static let showPerformance = Notification.Name("ChartdeskShowPerformance")
    static let focusAirportSearch = Notification.Name("ChartdeskFocusAirportSearch")
    static let focusChartSearch = Notification.Name("ChartdeskFocusChartSearch")
}

/// A real NSSearchField, so the rounded search look, the clear button and the system
/// text-editing behaviour all come for free.
struct MacSearchField: NSViewRepresentable {

    @Binding var text: String
    var placeholder: String
    var focusNotification: Notification.Name?
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldChanged(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.startObserving(name: focusNotification, field: field)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
    }

    static func dismantleNSView(_ nsView: NSSearchField, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onSubmit: (() -> Void)?

        private weak var field: NSSearchField?
        private var focusObserver: NSObjectProtocol?

        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            self.text = text
            self.onSubmit = onSubmit
            super.init()
        }

        func startObserving(name: Notification.Name?, field: NSSearchField) {
            self.field = field
            guard let name = name else { return }
            focusObserver = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let searchField = self?.field else { return }
                searchField.window?.makeFirstResponder(searchField)
            }
        }

        func stopObserving() {
            if let observer = focusObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            focusObserver = nil
        }

        @objc func searchFieldChanged(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let searchField = obj.object as? NSSearchField else { return }
            text.wrappedValue = searchField.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit?()
                return true
            }
            return false
        }
    }
}
