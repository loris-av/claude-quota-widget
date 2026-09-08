import QtQuick 2.15

// The Claude mascot, drawn as a grid of rectangles instead of an image file:
// it stays crisp at any panel height, needs no binary asset, and the wave is
// just a frame swap. Grid is 17 columns x 6 rows, one rectangle per pixel.
Item {
    id: mascot

    property color color: "#d77757"
    // Seconds between waves. Jittered per cycle so it never feels metronomic.
    property int waveIntervalSeconds: 45
    property bool animated: true

    readonly property int cols: 17
    readonly property int rows: 6

    // Row 0 is empty at rest -- that is the headroom the raised hand needs.
    readonly property var frameIdle: [
        "00000000000000000",
        "00111111111111100",
        "00110111111101100",   // the two gaps are the eyes
        "11111111111111111",   // arms stick out on both sides
        "00111111111111100",
        "00001010001010000"    // four feet
    ]
    // Right hand level with the eyes; the arm no longer juts out to the right.
    readonly property var frameMid: [
        "00000000000000000",
        "00111111111111100",
        "00110111111101111",
        "11111111111111100",
        "00111111111111100",
        "00001010001010000"
    ]
    // Hand up, with forearm cells linking it back down to the shoulder.
    readonly property var frameUp: [
        "00000000000000011",
        "00111111111111110",
        "00110111111101110",
        "11111111111111100",
        "00111111111111100",
        "00001010001010000"
    ]

    property var frame: frameIdle

    implicitHeight: 24

    // The source art uses tall cells -- 4 px wide by 8.4 px high -- so a cell
    // is twice as tall as it is wide. Square cells flatten the mascot.
    // Whole pixels only: a fractional cell size makes the art shimmer.
    // Derived from height only: implicitWidth follows from cellW, so reading
    // width here would close a binding loop.
    readonly property int cellW: Math.max(1, Math.floor(height / (rows * 2)))
    readonly property int cellH: cellW * 2

    implicitWidth: cellW * cols

    Item {
        width: mascot.cellW * mascot.cols
        height: mascot.cellH * mascot.rows
        anchors.centerIn: parent

        Repeater {
            model: mascot.cols * mascot.rows
            delegate: Rectangle {
                readonly property int col: index % mascot.cols
                readonly property int row: Math.floor(index / mascot.cols)
                x: col * mascot.cellW
                y: row * mascot.cellH
                width: mascot.cellW
                height: mascot.cellH
                color: mascot.color
                visible: mascot.frame[row].charAt(col) === "1"
            }
        }
    }

    function nextWaveDelay() {
        return Math.max(5, waveIntervalSeconds) * 1000 + Math.round(Math.random() * 15000)
    }

    // mid -> up -> mid -> up -> mid -> idle. Two beats, then stillness: no
    // animation runs between waves, so an idle panel costs nothing.
    SequentialAnimation {
        id: wave
        ScriptAction  { script: mascot.frame = mascot.frameMid }
        PauseAnimation { duration: 90 }
        ScriptAction  { script: mascot.frame = mascot.frameUp }
        PauseAnimation { duration: 200 }
        ScriptAction  { script: mascot.frame = mascot.frameMid }
        PauseAnimation { duration: 130 }
        ScriptAction  { script: mascot.frame = mascot.frameUp }
        PauseAnimation { duration: 200 }
        ScriptAction  { script: mascot.frame = mascot.frameMid }
        PauseAnimation { duration: 90 }
        ScriptAction  { script: mascot.frame = mascot.frameIdle }
    }

    Timer {
        interval: mascot.nextWaveDelay()
        running: mascot.animated
        repeat: true
        onTriggered: {
            if (!wave.running) wave.start()
            interval = mascot.nextWaveDelay()   // drops the binding on purpose
        }
    }
}
