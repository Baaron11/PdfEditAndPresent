//
//  RotationFrameDebugTests.swift
//  PdfEditAndPresentTests
//
//  Purpose: Debug and understand how UIView rotation transforms affect frame positioning
//  Problem: When rotating a canvas 90°/270°, the frame shifts to (252, -252) instead of (0, 0)
//

import XCTest
import UIKit

final class RotationFrameDebugTests: XCTestCase {

    // MARK: - Test Data (from the actual problem)

    /// Original canvas size (portrait PDF page)
    let originalCanvasSize = CGSize(width: 1713.6, height: 2217.6)

    /// Rotated canvas size (when 90° or 270° rotation is applied, dimensions swap)
    var rotatedContainerSize: CGSize {
        CGSize(width: originalCanvasSize.height, height: originalCanvasSize.width)
        // = CGSize(width: 2217.6, height: 1713.6)
    }

    // MARK: - Core Test: Understanding the Math

    func testRotationFrameMath() {
        print("\n" + "="*80)
        print("📐 ROTATION FRAME MATH DEBUG TEST")
        print("="*80)

        print("\n📋 Test Setup:")
        print("   Original canvas size: \(originalCanvasSize.width) × \(originalCanvasSize.height) (portrait)")
        print("   Container size after rotation: \(rotatedContainerSize.width) × \(rotatedContainerSize.height) (landscape)")

        // Create a container view (simulates the containerView in the app)
        let container = UIView(frame: CGRect(origin: .zero, size: rotatedContainerSize))

        // Create the canvas view (simulates pdfDrawingCanvas)
        let canvas = UIView()
        container.addSubview(canvas)

        print("\n" + "-"*80)
        testRotation(angle: 0, canvas: canvas, container: container)

        print("\n" + "-"*80)
        testRotation(angle: 90, canvas: canvas, container: container)

        print("\n" + "-"*80)
        testRotation(angle: 270, canvas: canvas, container: container)

        print("\n" + "="*80)
        printSolutionSummary()
        print("="*80 + "\n")
    }

    // MARK: - Test Individual Rotation

    private func testRotation(angle: Int, canvas: UIView, container: UIView) {
        let radians = CGFloat(angle) * .pi / 180.0
        let isRotated = (angle == 90 || angle == 270)

        print("\n🔄 TESTING \(angle)° ROTATION")
        print("-"*40)

        // Reset canvas
        canvas.transform = .identity

        // Step 1: Explain the goal
        let desiredFrame: CGRect
        if isRotated {
            desiredFrame = CGRect(x: 0, y: 0, width: originalCanvasSize.height, height: originalCanvasSize.width)
        } else {
            desiredFrame = CGRect(x: 0, y: 0, width: originalCanvasSize.width, height: originalCanvasSize.height)
        }
        print("\n🎯 GOAL: Frame should be at origin (0, 0)")
        print("   Desired frame: \(formatRect(desiredFrame))")

        // Step 2: Set bounds (logical size - always the original canvas dimensions)
        canvas.bounds = CGRect(origin: .zero, size: originalCanvasSize)
        print("\n📐 Step 1: Set bounds to original canvas size")
        print("   bounds = \(formatSize(originalCanvasSize))")

        // Step 3: Set center BEFORE rotation
        let centerBeforeTransform = CGPoint(
            x: originalCanvasSize.width / 2,
            y: originalCanvasSize.height / 2
        )
        canvas.center = centerBeforeTransform
        print("\n📐 Step 2: Set center BEFORE rotation")
        print("   center = \(formatPoint(centerBeforeTransform))")

        // Check frame BEFORE rotation
        print("\n📊 Frame BEFORE rotation transform:")
        print("   frame = \(formatRect(canvas.frame))")

        // Step 4: Apply rotation
        canvas.transform = CGAffineTransform(rotationAngle: radians)
        print("\n📐 Step 3: Apply rotation transform (\(angle)°)")
        print("   transform = CGAffineTransform(rotationAngle: \(radians))")

        // Check frame AFTER rotation
        print("\n❌ Frame AFTER rotation (PROBLEM):")
        print("   frame = \(formatRect(canvas.frame))")

        if isRotated {
            // Calculate the offset
            let offsetX = canvas.frame.origin.x
            let offsetY = canvas.frame.origin.y
            print("\n🔍 ANALYSIS:")
            print("   Frame shifted by: (\(offsetX), \(offsetY))")

            // Explain why
            let widthDiff = originalCanvasSize.width - originalCanvasSize.height
            let expectedOffset = widthDiff / 2
            print("   Width difference: \(originalCanvasSize.width) - \(originalCanvasSize.height) = \(widthDiff)")
            print("   Half of difference: \(widthDiff) / 2 = \(expectedOffset)")
            print("   This explains why offset = (\(expectedOffset), -\(expectedOffset))")
        }

        // Step 5: Try different position adjustments
        print("\n" + "-"*40)
        print("🔧 TESTING POSITION ADJUSTMENTS")
        print("-"*40)

        if isRotated {
            // Method 1: Adjust center after rotation to compensate
            testAdjustmentMethod1(angle: angle, canvas: canvas, container: container)

            // Method 2: Use layer.position with bounds.size/2 offset
            testAdjustmentMethod2(angle: angle, canvas: canvas, container: container)

            // Method 3: Calculate center based on rotated dimensions
            testAdjustmentMethod3(angle: angle, canvas: canvas, container: container)
        }
    }

    // MARK: - Adjustment Method Tests

    private func testAdjustmentMethod1(angle: Int, canvas: UIView, container: UIView) {
        let radians = CGFloat(angle) * .pi / 180.0

        print("\n📌 Method 1: Adjust center AFTER rotation to move frame to (0,0)")

        // Reset
        canvas.transform = .identity
        canvas.bounds = CGRect(origin: .zero, size: originalCanvasSize)

        // The frame after rotation will be offset - we need to calculate where center should be
        // Frame origin = center - bounds.size/2 (but rotated!)
        // After rotation, the frame width/height swap
        let rotatedFrameWidth = originalCanvasSize.height  // swapped
        let rotatedFrameHeight = originalCanvasSize.width   // swapped

        // For frame at (0, 0), center should be at (rotatedFrameWidth/2, rotatedFrameHeight/2)
        let targetCenter = CGPoint(
            x: rotatedFrameWidth / 2,
            y: rotatedFrameHeight / 2
        )

        canvas.center = targetCenter
        canvas.transform = CGAffineTransform(rotationAngle: radians)

        print("   Set center = \(formatPoint(targetCenter)) BEFORE rotation")
        print("   Applied rotation transform")
        print("   Result frame = \(formatRect(canvas.frame))")
        print("   ✅ SUCCESS? \(isFrameAtOrigin(canvas.frame) ? "YES!" : "NO")")
    }

    private func testAdjustmentMethod2(angle: Int, canvas: UIView, container: UIView) {
        let radians = CGFloat(angle) * .pi / 180.0

        print("\n📌 Method 2: Use anchorPoint adjustment")

        // Reset
        canvas.transform = .identity
        canvas.bounds = CGRect(origin: .zero, size: originalCanvasSize)
        canvas.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)  // default

        // Position at center of container
        canvas.center = CGPoint(
            x: container.bounds.width / 2,
            y: container.bounds.height / 2
        )

        canvas.transform = CGAffineTransform(rotationAngle: radians)

        print("   Center at container center = \(formatPoint(canvas.center))")
        print("   Result frame = \(formatRect(canvas.frame))")

        // Now try moving the frame to origin
        let currentFrame = canvas.frame
        let offsetNeeded = CGPoint(x: -currentFrame.origin.x, y: -currentFrame.origin.y)

        canvas.center = CGPoint(
            x: canvas.center.x + offsetNeeded.x,
            y: canvas.center.y + offsetNeeded.y
        )

        print("   Offset needed: \(formatPoint(offsetNeeded))")
        print("   New center = \(formatPoint(canvas.center))")
        print("   Final frame = \(formatRect(canvas.frame))")
        print("   ✅ SUCCESS? \(isFrameAtOrigin(canvas.frame) ? "YES!" : "NO")")
    }

    private func testAdjustmentMethod3(angle: Int, canvas: UIView, container: UIView) {
        let radians = CGFloat(angle) * .pi / 180.0

        print("\n📌 Method 3: Calculate center from desired frame after rotation")

        // Reset
        canvas.transform = .identity
        canvas.bounds = CGRect(origin: .zero, size: originalCanvasSize)

        // Key insight: After rotation, the frame dimensions swap
        // Frame.origin = center - (rotated_bounds_size / 2)
        // So: center = frame.origin + (rotated_bounds_size / 2)

        // For 90° rotation, the frame size becomes (height, width) of bounds
        let rotatedBoundsWidth = originalCanvasSize.height
        let rotatedBoundsHeight = originalCanvasSize.width

        // For frame at origin (0, 0):
        let neededCenter = CGPoint(
            x: 0 + rotatedBoundsWidth / 2,
            y: 0 + rotatedBoundsHeight / 2
        )

        canvas.center = neededCenter
        canvas.transform = CGAffineTransform(rotationAngle: radians)

        print("   Rotated bounds size: \(rotatedBoundsWidth) × \(rotatedBoundsHeight)")
        print("   For frame at (0,0), center needs to be at: \(formatPoint(neededCenter))")
        print("   Set center = \(formatPoint(neededCenter))")
        print("   Applied rotation")
        print("   Result frame = \(formatRect(canvas.frame))")
        print("   ✅ SUCCESS? \(isFrameAtOrigin(canvas.frame) ? "YES!" : "NO")")
    }

    // MARK: - The Correct Solution

    func testCorrectSolution() {
        print("\n" + "="*80)
        print("✅ CORRECT SOLUTION TEST")
        print("="*80)

        let container = UIView(frame: CGRect(origin: .zero, size: rotatedContainerSize))
        let canvas = UIView()
        container.addSubview(canvas)

        for angle in [0, 90, 180, 270] {
            let radians = CGFloat(angle) * .pi / 180.0
            let isRotated90or270 = (angle == 90 || angle == 270)

            print("\n🔄 \(angle)° Rotation:")

            // Step 1: Always set bounds to original canvas size
            canvas.bounds = CGRect(origin: .zero, size: originalCanvasSize)

            // Step 2: Calculate the correct center BEFORE applying rotation
            // After rotation, frame dimensions are swapped for 90°/270°
            let frameWidth: CGFloat
            let frameHeight: CGFloat

            if isRotated90or270 {
                frameWidth = originalCanvasSize.height   // swapped
                frameHeight = originalCanvasSize.width    // swapped
            } else {
                frameWidth = originalCanvasSize.width
                frameHeight = originalCanvasSize.height
            }

            // Center = frame.origin + frame.size/2
            // For frame at (0,0): center = (0,0) + (frameWidth/2, frameHeight/2)
            let correctCenter = CGPoint(
                x: frameWidth / 2,
                y: frameHeight / 2
            )

            canvas.center = correctCenter

            // Step 3: Apply rotation
            canvas.transform = CGAffineTransform(rotationAngle: radians)

            print("   bounds: \(formatSize(originalCanvasSize))")
            print("   center: \(formatPoint(correctCenter))")
            print("   frame:  \(formatRect(canvas.frame))")
            print("   ✅ At origin: \(isFrameAtOrigin(canvas.frame))")

            // Reset for next iteration
            canvas.transform = .identity
        }

        print("\n" + "="*80)
        print("📝 FORMULA SUMMARY")
        print("="*80)
        print("""

        For a view with bounds = (0, 0, W, H) rotated by angle degrees:

        1. Calculate frame dimensions AFTER rotation:
           - If angle is 90° or 270°:
             frameWidth = H (original height)
             frameHeight = W (original width)
           - Otherwise:
             frameWidth = W
             frameHeight = H

        2. Set center BEFORE applying rotation:
           center.x = desiredFrameX + frameWidth/2
           center.y = desiredFrameY + frameHeight/2

        3. Apply rotation transform

        For frame at origin (0, 0):
           center = (frameWidth/2, frameHeight/2)

        With your values:
        - Original: 1713.6 × 2217.6
        - For 90°/270° rotation:
          - Frame after rotation: 2217.6 × 1713.6
          - Center should be: (2217.6/2, 1713.6/2) = (1108.8, 856.8)
        """)
    }

    // MARK: - Test Why the Current Code Fails

    func testExplainCurrentCodeFailure() {
        print("\n" + "="*80)
        print("🔴 WHY THE CURRENT CODE FAILS")
        print("="*80)

        let container = UIView(frame: CGRect(origin: .zero, size: rotatedContainerSize))
        let canvas = UIView()
        container.addSubview(canvas)

        let angle = 270
        let radians = CGFloat(angle) * .pi / 180.0

        print("""

        Current code does this:
        1. Sets canvas.frame = (0, 0, 1713.6, 2217.6)
        2. Applies rotation transform

        Let's trace what happens:
        """)

        // Simulate current code
        canvas.transform = .identity
        canvas.frame = CGRect(origin: .zero, size: originalCanvasSize)

        print("\n📊 BEFORE rotation:")
        print("   frame: \(formatRect(canvas.frame))")
        print("   bounds: \(formatRect(canvas.bounds))")
        print("   center: \(formatPoint(canvas.center))")

        // The center is at the middle of the frame
        let centerBeforeRotation = canvas.center
        print("\n   When frame = (0, 0, W, H), center = (W/2, H/2) = \(formatPoint(centerBeforeRotation))")

        canvas.transform = CGAffineTransform(rotationAngle: radians)

        print("\n📊 AFTER rotation:")
        print("   frame: \(formatRect(canvas.frame))")
        print("   bounds: \(formatRect(canvas.bounds))  (unchanged)")
        print("   center: \(formatPoint(canvas.center))  (unchanged)")

        print("""

        🔍 EXPLANATION:

        The center stays the same after rotation, but the frame changes because:
        - Frame is calculated from center, bounds, and transform
        - frame.origin = center - (transformed_bounds_size / 2)

        Before rotation:
          bounds size = (\(originalCanvasSize.width), \(originalCanvasSize.height))
          center = (\(centerBeforeRotation.x), \(centerBeforeRotation.y))
          frame.origin = center - bounds/2
                       = (\(centerBeforeRotation.x) - \(originalCanvasSize.width)/2,
                          \(centerBeforeRotation.y) - \(originalCanvasSize.height)/2)
                       = (0, 0) ✅

        After 270° rotation:
          bounds size stays = (\(originalCanvasSize.width), \(originalCanvasSize.height))
          BUT transformed bounds size = (\(originalCanvasSize.height), \(originalCanvasSize.width))  ← SWAPPED!
          center stays = (\(centerBeforeRotation.x), \(centerBeforeRotation.y))
          frame.origin = center - transformed_bounds/2
                       = (\(centerBeforeRotation.x) - \(originalCanvasSize.height)/2,
                          \(centerBeforeRotation.y) - \(originalCanvasSize.width)/2)
                       = (\(centerBeforeRotation.x - originalCanvasSize.height/2),
                          \(centerBeforeRotation.y - originalCanvasSize.width/2))

        The offset of (\(centerBeforeRotation.x - originalCanvasSize.height/2), \(centerBeforeRotation.y - originalCanvasSize.width/2))
        = (\((originalCanvasSize.width - originalCanvasSize.height)/2), \((originalCanvasSize.height - originalCanvasSize.width)/2))
        = (252, -252)  ← This is the (252, -252) you're seeing!
        """)
    }

    // MARK: - Generate Code for App

    func testGenerateAppCode() {
        print("\n" + "="*80)
        print("📝 CODE FOR UnifiedBoardCanvasController.swift")
        print("="*80)

        print("""

        Replace the applyTransforms() method with:

        ```swift
        private func applyTransforms() {
            guard let transformer = transformer else {
                print("🔄 [TRANSFORM] applyTransforms() called but transformer is nil")
                return
            }

            print("🔄 [TRANSFORM] applyTransforms() called")
            print("🔄 [TRANSFORM]   canvasSize: \\(canvasSize.width) x \\(canvasSize.height)")
            print("🔄 [TRANSFORM]   currentPageRotation: \\(currentPageRotation)°")

            // Apply display transform to pdfHost (PaperKit) only
            let displayTransform = transformer.displayTransform
            paperKitView?.transform = displayTransform

            // Calculate rotation
            let rotationRadians = CGFloat(currentPageRotation) * .pi / 180.0
            let isRotated90or270 = (currentPageRotation == 90 || currentPageRotation == 270)

            // After rotation, the frame dimensions swap for 90°/270°
            let frameWidth: CGFloat
            let frameHeight: CGFloat

            if isRotated90or270 {
                frameWidth = canvasSize.height   // swapped
                frameHeight = canvasSize.width   // swapped
            } else {
                frameWidth = canvasSize.width
                frameHeight = canvasSize.height
            }

            // Update container bounds to match rotated dimensions
            containerView.bounds = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)

            // Configure canvas views
            // 1. Set bounds to original canvas size (logical drawing area)
            pdfDrawingCanvas?.bounds = CGRect(origin: .zero, size: canvasSize)
            marginDrawingCanvas?.bounds = CGRect(origin: .zero, size: canvasSize)

            // 2. Set center so that frame will be at (0, 0) after rotation
            //    Formula: center = (frameWidth/2, frameHeight/2)
            let correctCenter = CGPoint(x: frameWidth / 2, y: frameHeight / 2)
            pdfDrawingCanvas?.center = correctCenter
            marginDrawingCanvas?.center = correctCenter

            // 3. Apply rotation transform
            let rotationTransform = CGAffineTransform(rotationAngle: rotationRadians)
            pdfDrawingCanvas?.transform = rotationTransform
            marginDrawingCanvas?.transform = rotationTransform

            print("🔄 [TRANSFORM]   frameSize: \\(frameWidth) x \\(frameHeight)")
            print("🔄 [TRANSFORM]   center: \\(correctCenter)")
            print("🔄 [TRANSFORM]   pdfDrawingCanvas.frame: \\(pdfDrawingCanvas?.frame ?? .zero)")

            // Update margin canvas visibility
            marginDrawingCanvas?.isHidden = !marginSettings.isEnabled
        }
        ```

        KEY INSIGHT:
        Setting canvas.frame = CGRect(x: 0, y: 0, ...) BEFORE rotation doesn't work
        because the frame is recalculated after rotation based on center and transformed bounds.

        Instead, you must:
        1. Set bounds (the logical size, unchanged by rotation)
        2. Set center to where you want the frame center to be AFTER rotation
        3. Apply the rotation transform

        The center calculation accounts for the fact that after rotation,
        the frame width and height are swapped for 90°/270° rotations.
        """)
    }

    // MARK: - Helper Methods

    private func isFrameAtOrigin(_ frame: CGRect) -> Bool {
        return abs(frame.origin.x) < 0.1 && abs(frame.origin.y) < 0.1
    }

    private func formatRect(_ rect: CGRect) -> String {
        return String(format: "(%.1f, %.1f, %.1f, %.1f)", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    private func formatSize(_ size: CGSize) -> String {
        return String(format: "(%.1f × %.1f)", size.width, size.height)
    }

    private func formatPoint(_ point: CGPoint) -> String {
        return String(format: "(%.1f, %.1f)", point.x, point.y)
    }

    private func printSolutionSummary() {
        print("""

        ╔══════════════════════════════════════════════════════════════════════════════╗
        ║                              SOLUTION SUMMARY                                ║
        ╠══════════════════════════════════════════════════════════════════════════════╣
        ║                                                                              ║
        ║  PROBLEM: Frame shifts to (252, -252) after 90°/270° rotation                ║
        ║                                                                              ║
        ║  ROOT CAUSE:                                                                 ║
        ║  - Setting frame BEFORE rotation, then rotation recalculates it              ║
        ║  - frame = center - transformed_bounds_size/2                                ║
        ║  - When bounds are rotated 90°, their effective size swaps                   ║
        ║                                                                              ║
        ║  SOLUTION:                                                                   ║
        ║  1. Set bounds = original canvas size (1713.6 × 2217.6)                      ║
        ║  2. Calculate frame size AFTER rotation (swapped for 90°/270°)               ║
        ║  3. Set center = (frameWidth/2, frameHeight/2) for frame at origin           ║
        ║  4. Apply rotation transform LAST                                            ║
        ║                                                                              ║
        ║  For 270° rotation:                                                          ║
        ║  - Frame after rotation: 2217.6 × 1713.6                                     ║
        ║  - Center should be: (1108.8, 856.8)                                         ║
        ║                                                                              ║
        ╚══════════════════════════════════════════════════════════════════════════════╝
        """)
    }
}

// MARK: - String Extension for Test Output

private extension String {
    static func *(left: String, right: Int) -> String {
        return String(repeating: left, count: right)
    }
}
