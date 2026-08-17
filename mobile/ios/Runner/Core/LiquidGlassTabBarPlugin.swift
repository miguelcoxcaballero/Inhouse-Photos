import Flutter
import UIKit

final class LiquidGlassTabBarPlugin: NSObject, FlutterPlugin {
  static let name = "LiquidGlassTabBarPlugin"
  private static let viewType = "com.inhousesoftware.photos/liquid_glass_tab_bar"

  static func register(with registrar: any FlutterPluginRegistrar) {
    registrar.register(
      LiquidGlassTabBarFactory(messenger: registrar.messenger()),
      withId: viewType
    )
  }
}

private final class LiquidGlassTabBarFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> any FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> any FlutterPlatformView {
    LiquidGlassTabBarPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args as? [String: Any],
      messenger: messenger
    )
  }
}

private final class LiquidGlassTabBarPlatformView: NSObject, FlutterPlatformView {
  private let tabBarView: LiquidGlassTabBarView
  private let channel: FlutterMethodChannel

  init(
    frame: CGRect,
    viewId: Int64,
    arguments: [String: Any]?,
    messenger: FlutterBinaryMessenger
  ) {
    channel = FlutterMethodChannel(
      name: "com.inhousesoftware.photos/liquid_glass_tab_bar/\(viewId)",
      binaryMessenger: messenger
    )
    tabBarView = LiquidGlassTabBarView(frame: frame)
    super.init()

    tabBarView.onSelected = { [weak channel] index in
      channel?.invokeMethod("onSelected", arguments: index)
    }
    tabBarView.apply(arguments)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setState" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.tabBarView.apply(call.arguments as? [String: Any])
      result(nil)
    }
  }

  func view() -> UIView {
    tabBarView
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }
}

private final class IndexedTabButton: UIButton {
  let tabIndex: Int

  init(tabIndex: Int) {
    self.tabIndex = tabIndex
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    nil
  }
}

private final class LiquidGlassTabBarView: UIView {
  private static let copper = UIColor(red: 217 / 255, green: 119 / 255, blue: 54 / 255, alpha: 1)
  private static let symbols = [
    "photo.on.rectangle.angled",
    "magnifyingglass",
    "rectangle.stack",
    "square.grid.2x2",
  ]

  var onSelected: ((Int) -> Void)?

  private let capsule = UIView()
  private let glassView: UIVisualEffectView
  private let selectionGlass: UIVisualEffectView
  private var buttons: [IndexedTabButton] = []
  private var labels = ["Photos", "Search", "Albums", "Library"]
  private var enabled = [true, true, true, true]
  private var selectedIndex = 0

  override init(frame: CGRect) {
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      glass.tintColor = UIColor.white.withAlphaComponent(0.035)
      glassView = UIVisualEffectView(effect: glass)

      let selection = UIGlassEffect(style: .regular)
      selection.isInteractive = true
      selection.tintColor = Self.copper.withAlphaComponent(0.20)
      selectionGlass = UIVisualEffectView(effect: selection)
    } else {
      glassView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
      selectionGlass = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    }

    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    capsule.backgroundColor = .clear
    capsule.layer.shadowColor = UIColor.black.cgColor
    capsule.layer.shadowOpacity = 0.22
    capsule.layer.shadowRadius = 18
    capsule.layer.shadowOffset = CGSize(width: 0, height: 8)
    addSubview(capsule)

    glassView.clipsToBounds = true
    glassView.layer.borderWidth = 0.75
    glassView.layer.borderColor = UIColor.white.withAlphaComponent(0.30).cgColor
    capsule.addSubview(glassView)

    selectionGlass.clipsToBounds = true
    selectionGlass.isUserInteractionEnabled = false
    selectionGlass.layer.borderWidth = 0.65
    selectionGlass.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
    glassView.contentView.addSubview(selectionGlass)

    for index in 0..<Self.symbols.count {
      let button = IndexedTabButton(tabIndex: index)
      button.addTarget(self, action: #selector(selectTab(_:)), for: .touchUpInside)
      button.addTarget(self, action: #selector(pressTab(_:)), for: [.touchDown, .touchDragEnter])
      button.addTarget(self, action: #selector(releaseTab(_:)), for: [.touchUpInside, .touchCancel, .touchDragExit])
      glassView.contentView.addSubview(button)
      buttons.append(button)
    }
    updateButtons()
  }

  required init?(coder: NSCoder) {
    nil
  }

  func apply(_ arguments: [String: Any]?) {
    guard let arguments else { return }
    if let index = arguments["selectedIndex"] as? NSNumber {
      selectedIndex = min(max(index.intValue, 0), buttons.count - 1)
    }
    if let newLabels = arguments["labels"] as? [String], newLabels.count == buttons.count {
      labels = newLabels
    }
    if let newEnabled = arguments["enabled"] as? [Bool], newEnabled.count == buttons.count {
      enabled = newEnabled
    } else if let values = arguments["enabled"] as? [NSNumber], values.count == buttons.count {
      enabled = values.map(\.boolValue)
    }
    updateButtons()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let verticalInset: CGFloat = 2
    capsule.frame = bounds.insetBy(dx: 0, dy: verticalInset)
    capsule.layer.shadowPath = UIBezierPath(roundedRect: capsule.bounds, cornerRadius: capsule.bounds.height / 2).cgPath
    glassView.frame = capsule.bounds
    glassView.layer.cornerRadius = capsule.bounds.height / 2

    guard !buttons.isEmpty else { return }
    let slotWidth = glassView.bounds.width / CGFloat(buttons.count)
    for (index, button) in buttons.enumerated() {
      button.frame = CGRect(x: CGFloat(index) * slotWidth, y: 0, width: slotWidth, height: glassView.bounds.height)
    }

    let indicatorFrame = CGRect(
      x: CGFloat(selectedIndex) * slotWidth + 4,
      y: 4,
      width: slotWidth - 8,
      height: glassView.bounds.height - 8
    )
    selectionGlass.layer.cornerRadius = indicatorFrame.height / 2
    if selectionGlass.frame == .zero || UIAccessibility.isReduceMotionEnabled {
      selectionGlass.frame = indicatorFrame
    } else if selectionGlass.frame != indicatorFrame {
      UIView.animate(
        withDuration: 0.34,
        delay: 0,
        usingSpringWithDamping: 0.82,
        initialSpringVelocity: 0.28,
        options: [.allowUserInteraction, .beginFromCurrentState]
      ) {
        self.selectionGlass.frame = indicatorFrame
      }
    }
  }

  private func updateButtons() {
    for (index, button) in buttons.enumerated() {
      let isSelected = index == selectedIndex
      var configuration = UIButton.Configuration.plain()
      configuration.title = labels[index]
      configuration.image = UIImage(systemName: Self.symbols[index])
      configuration.imagePlacement = .top
      configuration.imagePadding = 2
      configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 4, trailing: 2)
      configuration.baseForegroundColor = isSelected
        ? Self.copper
        : UIColor.label.withAlphaComponent(enabled[index] ? 0.72 : 0.28)
      configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
        var attributes = attributes
        attributes.font = .systemFont(ofSize: 11, weight: isSelected ? .semibold : .medium)
        return attributes
      }
      button.configuration = configuration
      button.isEnabled = enabled[index]
      button.accessibilityLabel = labels[index]
      button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
      if !enabled[index] {
        button.accessibilityTraits.insert(.notEnabled)
      }
    }
  }

  @objc private func selectTab(_ sender: IndexedTabButton) {
    guard enabled[sender.tabIndex] else { return }
    UISelectionFeedbackGenerator().selectionChanged()
    onSelected?(sender.tabIndex)
  }

  @objc private func pressTab(_ sender: IndexedTabButton) {
    guard !UIAccessibility.isReduceMotionEnabled else { return }
    UIView.animate(withDuration: 0.10) {
      sender.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
    }
  }

  @objc private func releaseTab(_ sender: IndexedTabButton) {
    UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.4) {
      sender.transform = .identity
    }
  }
}
