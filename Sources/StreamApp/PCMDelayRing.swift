/// Preallocated interleaved PCM storage. Startup withholds samples, not leading silence.
struct PCMDelayRing {
    private var storage: [Float]
    private var readIndex = 0
    private var count = 0
    private let delaySamples: Int
    init(delaySamples: Int, blockSamples: Int) {
        self.delaySamples = max(0, delaySamples)
        storage = [Float](repeating: 0, count: max(1, delaySamples + blockSamples))
    }
    var bufferedSamples: Int { count }
    mutating func append(_ input: UnsafeBufferPointer<Float>, output: UnsafeMutableBufferPointer<Float>) -> Int {
        precondition(count + input.count <= storage.count)
        for sample in input {
            storage[(readIndex + count) % storage.count] = sample
            count += 1
        }
        return drain(into: output, maximum: max(0, count - delaySamples))
    }
    mutating func flush(into output: UnsafeMutableBufferPointer<Float>) -> Int { drain(into: output, maximum: count) }
    private mutating func drain(into output: UnsafeMutableBufferPointer<Float>, maximum: Int) -> Int {
        let amount = min(output.count, maximum)
        for index in 0..<amount { output[index] = storage[(readIndex + index) % storage.count] }
        readIndex = (readIndex + amount) % storage.count
        count -= amount
        return amount
    }
}
