import Foundation

func captureAudioLevel(decibels: Float) -> Double {
  guard decibels > -60 else { return 0 }
  let amplitude = pow(10, Double(decibels) / 20)
  return pow(min(amplitude * 3.2, 1), 0.55)
}
