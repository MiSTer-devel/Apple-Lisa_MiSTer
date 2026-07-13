// ps2_to_usb_hid.sv
// Translates raw PS/2 scancodes from MiSTer HPS to a stream of key EVENTS.
// Each make/break emits one `report` pulse carrying {key_code, key_press}.
// key_code is the HID usage of the key that changed (modifier keys use the HID
// modifier usages 0xE0-0xE6). This event stream (vs the old single held-key
// level) lets the adapter queue overlapping keys without dropping releases.

`timescale 1 ns / 1 ps

module ps2_to_usb_hid (
    input  wire        clk,             // System clock
    input  wire        reset,           // System reset
    input  wire [10:0] ps2_key,         // PS/2 scancode from HPS
    output reg         key_press,       // 1 = make (down), 0 = break (up)
    output reg   [7:0] key_code,        // HID usage of the key that changed
    output reg         report           // 1-clk pulse per mappable key event
);

    reg old_strobe;
    always_ff @(posedge clk) begin
        if (reset) begin
            old_strobe <= 1'b0;
            key_press <= 1'b0;
            key_code <= 8'h00;
            report <= 1'b0;
        end else begin
            old_strobe <= ps2_key[10];
            report <= 1'b0;

            if (old_strobe != ps2_key[10]) begin
                logic [8:0] scancode;
                logic press;
                logic [7:0] hid_code;
                
                scancode = ps2_key[8:0];
                press = ps2_key[9];

                // Translate scancode to HID keycode
                case (scancode)
                    // Letters
                    9'h01C: hid_code = 8'h04; // A
                    9'h032: hid_code = 8'h05; // B
                    9'h021: hid_code = 8'h06; // C
                    9'h023: hid_code = 8'h07; // D
                    9'h024: hid_code = 8'h08; // E
                    9'h02B: hid_code = 8'h09; // F
                    9'h034: hid_code = 8'h0A; // G
                    9'h033: hid_code = 8'h0B; // H
                    9'h043: hid_code = 8'h0C; // I
                    9'h03B: hid_code = 8'h0D; // J
                    9'h042: hid_code = 8'h0E; // K
                    9'h04B: hid_code = 8'h0F; // L
                    9'h03A: hid_code = 8'h10; // M
                    9'h031: hid_code = 8'h11; // N
                    9'h044: hid_code = 8'h12; // O
                    9'h04D: hid_code = 8'h13; // P
                    9'h015: hid_code = 8'h14; // Q
                    9'h02D: hid_code = 8'h15; // R
                    9'h01B: hid_code = 8'h16; // S
                    9'h02C: hid_code = 8'h17; // T
                    9'h03C: hid_code = 8'h18; // U
                    9'h02A: hid_code = 8'h19; // V
                    9'h01D: hid_code = 8'h1A; // W
                    9'h022: hid_code = 8'h1B; // X
                    9'h035: hid_code = 8'h1C; // Y
                    9'h01A: hid_code = 8'h1D; // Z

                    // Numbers
                    9'h016: hid_code = 8'h1E; // 1
                    9'h01E: hid_code = 8'h1F; // 2
                    9'h026: hid_code = 8'h20; // 3
                    9'h025: hid_code = 8'h21; // 4
                    9'h02E: hid_code = 8'h22; // 5
                    9'h036: hid_code = 8'h23; // 6
                    9'h03D: hid_code = 8'h24; // 7
                    9'h03E: hid_code = 8'h25; // 8
                    9'h046: hid_code = 8'h26; // 9
                    9'h045: hid_code = 8'h27; // 0

                    // Control / Special keys
                    9'h05A: hid_code = 8'h28; // Enter
                    9'h076: hid_code = 8'h29; // Escape
                    9'h066: hid_code = 8'h2A; // Backspace
                    9'h00D: hid_code = 8'h2B; // Tab
                    9'h029: hid_code = 8'h2C; // Space
                    9'h04E: hid_code = 8'h2D; // -
                    9'h055: hid_code = 8'h2E; // =
                    9'h054: hid_code = 8'h2F; // [
                    9'h05B: hid_code = 8'h30; // ]
                    9'h05D: hid_code = 8'h31; // \
                    9'h04C: hid_code = 8'h33; // ;
                    9'h052: hid_code = 8'h34; // '
                    9'h00E: hid_code = 8'h35; // `
                    9'h041: hid_code = 8'h36; // ,
                    9'h049: hid_code = 8'h37; // .
                    9'h04A: hid_code = 8'h38; // /
                    9'h058: hid_code = 8'h39; // Caps Lock

                    // Keypad Digits
                    9'h069: hid_code = 8'h59; // KP 1
                    9'h072: hid_code = 8'h5A; // KP 2
                    9'h07A: hid_code = 8'h5B; // KP 3
                    9'h06B: hid_code = 8'h5C; // KP 4
                    9'h073: hid_code = 8'h5D; // KP 5
                    9'h074: hid_code = 8'h5E; // KP 6
                    9'h06C: hid_code = 8'h5F; // KP 7
                    9'h075: hid_code = 8'h60; // KP 8
                    9'h07D: hid_code = 8'h61; // KP 9
                    9'h070: hid_code = 8'h62; // KP 0
                    9'h071: hid_code = 8'h63; // KP .
                    9'h15A: hid_code = 8'h58; // KP Enter
                    9'h077: hid_code = 8'h53; // KP NumLock / Clear

                    // Keypad Operators
                    9'h14A: hid_code = 8'h54; // KP /
                    9'h07C: hid_code = 8'h55; // KP *
                    9'h07B: hid_code = 8'h56; // KP -
                    9'h079: hid_code = 8'h57; // KP +

                    // Arrow keys
                    9'h175: hid_code = 8'h52; // Up
                    9'h16B: hid_code = 8'h50; // Left
                    9'h174: hid_code = 8'h4F; // Right
                    9'h172: hid_code = 8'h51; // Down

                    // Modifiers get their HID modifier usages (0xE0-0xE6) so the
                    // adapter can map them; they are events like any other key.
                    9'h012: hid_code = 8'hE1; // Left Shift
                    9'h059: hid_code = 8'hE5; // Right Shift
                    9'h014: hid_code = 8'hE0; // Left Control  -> Left Option
                    9'h114: hid_code = 8'hE4; // Right Control -> Right Option
                    9'h011: hid_code = 8'hE2; // Left Alt      -> Apple
                    9'h111: hid_code = 8'hE6; // Right Alt     -> Apple

                    default: hid_code = 8'h00;
                endcase

                // Emit one event per make/break. No held-key level state, so
                // overlapping keys (rollover) each produce their own event and
                // cannot clobber each other's release.
                if (hid_code != 8'h00) begin
                    key_code  <= hid_code;
                    key_press <= press;
                    report    <= 1'b1;
                end
            end
        end
    end

endmodule
