import Foundation

@main
struct LyricsTests {
    static func main() {
        let lines = Lyrics.parse("[ar:Artist]\n[offset:250]\n[00:01.20][00:03.456]你好\n[00:02]World\n[00:70.0]invalid")
        assert(lines.count == 3)
        assert(abs(lines[0].time - 1.45) < 0.001)
        assert(lines[0].text == "你好")
        assert(abs(lines[1].time - 2.25) < 0.001)
        assert(abs(lines[2].time - 3.706) < 0.001)
        assert(lines.map(\.id) == [0, 1, 2])
        assert(Lyrics.parse("plain text without timestamps").isEmpty)
        assert(Lyrics.parse("[offset:-2000]\n[00:01]test")[0].time == 0)
        assert(Lyrics.parse("[00:02.5]x")[0].time == 2.5)
        print("Lyrics parser tests passed")
    }
}
