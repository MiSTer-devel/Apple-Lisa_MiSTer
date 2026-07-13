`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 12/15/2025 05:49:45 PM
// Design Name: 
// Module Name: usb_keyboard_interface
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module usb_keyboard_interface(
    input logic clk_sys,
    input logic usbclk_en,
    input logic usbrst,
    input logic [7:0] key_code_in,   // HID usage of the key that changed
    input logic       key_press_in,  // 1 = make (down), 0 = break (up)
    input logic report,              // 1-clk_sys pulse per key event
    input logic KBD_in,
    output logic KBD_out,
    output logic caps_lock_led    // current Caps Lock state -> host keyboard LED
    );
    assign caps_lock_led = caps_lock_state;

    // First, let's synchronize KBD_in to the usbclk domain to avoid metastability issues
    (* ASYNC_REG = "TRUE" *) logic KBD_in_int, KBD_in_sync;
    always_ff @(posedge clk_sys) begin
        if (usbclk_en) begin
            KBD_in_int <= KBD_in;
            KBD_in_sync <= KBD_in_int;
        end
    end

    // (Key events are no longer latched as a single held-key level; they are
    //  mapped and queued in the FIFO below.)

    // We've got the key states latched now, so let's output them in the format the Lisa expects
    // This is the trickier part
    // The Lisa's keyboard protocol is as follows:
    // Both KBD_in and KBD_out are active-low signals
    // When KBD_in goes low for about 20us (which happens about every 1ms), the Lisa is requesting a key state update
    // The keyboard is expected to respond about 20us later if it has any key updates to send, if not it just leaves KBD_out high
    // If it does have something to report, it responds (20us after KBD_in goes low) by sending out a 16us long start bit (KBD_out low)
    // The start bit is followed by 8 data bits representing the keycode
    // All bits are transmitted inverted (0 = high, 1 = low) and they all take time 16us, except D7 which is 30us long
    // They're sent in the order D4, D5, D6, D7, D0, D1, D2, D3 (weirdly)
    // After the last bit, KBD_out goes high again
    // Another case: immediately after the system is reset, the keyboard is expected to send an ID code to the Lisa
    // First we send an 0x80 keyboard ID and then an 0xBF to identify it as a US keyboard layout
    // Same format as above, and we still wait for 20us sync pulses before sending each byte
    // The Lisa can also request a reset at any time by pulling KBD_in low for at least 5ms
    // We translate USB keyboard keycodes to Lisa keycodes using a lookup table

    typedef enum logic [6:0] {
        IDLE,
        WAIT_FOR_HIGH,
        WAIT_TO_SEND,
        SEND_START_BIT,
        SEND_D4,
        SEND_D5,
        SEND_D6,
        SEND_D7,
        SEND_D0,
        SEND_D1,
        SEND_D2,
        SEND_D3,
        FINISHED,
        KBD_RESET
    } kbd_state_t;

    kbd_state_t kbd_state;

    logic [25:0] kbd_in_pulse_counter; // Counts how long KBD_in has been low
    logic [9:0] kbd_bit_timer; // Timer for sending bits (16us or 30us)

    // The keycode in Lisa format to send
    logic [7:0] lisa_keycode;

    // And a lookup table to convert USB HID keycodes to Lisa keycodes
    // I'm not going to pretend that I wrote this myself; it sounded like a lot of work so I asked ChatGPT to generate it for me
    // USB HID usage (0x00–0x7F) -> Apple Lisa keycode
    logic [7:0] lisa_keycode_hid [0:127];
    initial begin
        integer i;
        for (i = 0; i < 128; i++)
            lisa_keycode_hid[i] = 8'h00;

        // ----------------------------------------------------------------
        // Letters (HID 0x04–0x1D)
        // ----------------------------------------------------------------
        lisa_keycode_hid[8'h04] = 8'h70; // A
        lisa_keycode_hid[8'h05] = 8'h6E; // B
        lisa_keycode_hid[8'h06] = 8'h6D; // C
        lisa_keycode_hid[8'h07] = 8'h7B; // D
        lisa_keycode_hid[8'h08] = 8'h60; // E
        lisa_keycode_hid[8'h09] = 8'h69; // F
        lisa_keycode_hid[8'h0A] = 8'h6A; // G
        lisa_keycode_hid[8'h0B] = 8'h6B; // H
        lisa_keycode_hid[8'h0C] = 8'h53; // I
        lisa_keycode_hid[8'h0D] = 8'h54; // J
        lisa_keycode_hid[8'h0E] = 8'h55; // K
        lisa_keycode_hid[8'h0F] = 8'h59; // L
        lisa_keycode_hid[8'h10] = 8'h58; // M
        lisa_keycode_hid[8'h11] = 8'h6F; // N
        lisa_keycode_hid[8'h12] = 8'h5F; // O
        lisa_keycode_hid[8'h13] = 8'h44; // P
        lisa_keycode_hid[8'h14] = 8'h75; // Q
        lisa_keycode_hid[8'h15] = 8'h65; // R
        lisa_keycode_hid[8'h16] = 8'h76; // S
        lisa_keycode_hid[8'h17] = 8'h66; // T
        lisa_keycode_hid[8'h18] = 8'h52; // U
        lisa_keycode_hid[8'h19] = 8'h6C; // V
        lisa_keycode_hid[8'h1A] = 8'h77; // W
        lisa_keycode_hid[8'h1B] = 8'h7A; // X
        lisa_keycode_hid[8'h1C] = 8'h67; // Y
        lisa_keycode_hid[8'h1D] = 8'h79; // Z

        // ----------------------------------------------------------------
        // Number row
        // ----------------------------------------------------------------
        lisa_keycode_hid[8'h1E] = 8'h74; // 1 !
        lisa_keycode_hid[8'h1F] = 8'h71; // 2 @
        lisa_keycode_hid[8'h20] = 8'h72; // 3 #
        lisa_keycode_hid[8'h21] = 8'h73; // 4 $
        lisa_keycode_hid[8'h22] = 8'h64; // 5 %
        lisa_keycode_hid[8'h23] = 8'h61; // 6 ^
        lisa_keycode_hid[8'h24] = 8'h62; // 7 &
        lisa_keycode_hid[8'h25] = 8'h63; // 8 *
        lisa_keycode_hid[8'h26] = 8'h50; // 9 (
        lisa_keycode_hid[8'h27] = 8'h51; // 0 )

        // ----------------------------------------------------------------
        // Punctuation / symbols
        // ----------------------------------------------------------------
        lisa_keycode_hid[8'h28] = 8'h48; // Enter (main Return)
        lisa_keycode_hid[8'h29] = 8'h68; // Esc -> ` ~ (Esc in LisaTerminal)
        lisa_keycode_hid[8'h2A] = 8'h45; // Backspace
        lisa_keycode_hid[8'h2B] = 8'h78; // Tab
        lisa_keycode_hid[8'h2C] = 8'h5C; // Space
        lisa_keycode_hid[8'h39] = 8'h7D; // Caps Lock

        lisa_keycode_hid[8'h2D] = 8'h40; // - _
        lisa_keycode_hid[8'h2E] = 8'h41; // = +
        lisa_keycode_hid[8'h2F] = 8'h56; // [ {
        lisa_keycode_hid[8'h30] = 8'h57; // ] }
        lisa_keycode_hid[8'h31] = 8'h42; // \ | (ANSI backslash)
        lisa_keycode_hid[8'h32] = 8'h42; // \ | (ISO backslash)
        lisa_keycode_hid[8'h33] = 8'h5A; // ; :
        lisa_keycode_hid[8'h34] = 8'h5B; // ' "
        lisa_keycode_hid[8'h35] = 8'h68; // ` ~
        lisa_keycode_hid[8'h36] = 8'h5D; // , <
        lisa_keycode_hid[8'h37] = 8'h5E; // . >
        lisa_keycode_hid[8'h38] = 8'h4C; // / ?
        lisa_keycode_hid[8'h64] = 8'h43; // < > (ISO 102nd key)
        lisa_keycode_hid[8'h65] = 8'h46; // Menu -> third Enter key

        // ------------------------------------------------------------
        // Keypad operators
        // ------------------------------------------------------------
        lisa_keycode_hid[8'h54] = 8'h27; // KP /
        lisa_keycode_hid[8'h55] = 8'h23; // KP *
        lisa_keycode_hid[8'h56] = 8'h21; // KP -
        lisa_keycode_hid[8'h57] = 8'h22; // KP +
        lisa_keycode_hid[8'h63] = 8'h2C; // KP .
        lisa_keycode_hid[8'h67] = 8'h2B; // KP = (Mac USB kbd) -> KP , (Lisa kbd)

        // ------------------------------------------------------------
        // Keypad digits
        // ------------------------------------------------------------
        lisa_keycode_hid[8'h59] = 8'h4D; // KP 1
        lisa_keycode_hid[8'h5A] = 8'h2D; // KP 2
        lisa_keycode_hid[8'h5B] = 8'h2E; // KP 3
        lisa_keycode_hid[8'h5C] = 8'h28; // KP 4
        lisa_keycode_hid[8'h5D] = 8'h29; // KP 5
        lisa_keycode_hid[8'h5E] = 8'h2A; // KP 6
        lisa_keycode_hid[8'h5F] = 8'h24; // KP 7
        lisa_keycode_hid[8'h60] = 8'h25; // KP 8
        lisa_keycode_hid[8'h61] = 8'h26; // KP 9
        lisa_keycode_hid[8'h62] = 8'h49; // KP 0

        // ------------------------------------------------------------
        // Keypad Enter
        // ------------------------------------------------------------
        lisa_keycode_hid[8'h58] = 8'h2F; // KP Enter -> Lisa Numpad Enter
        lisa_keycode_hid[8'h53] = 8'h20; // KP NumLock/Clear -> Lisa Clear

        // ------------------------------------------------------------
        // Arrow keys mapped to keypad
        // Apple Lisa and very early Macintosh used KP / , + * as arrow keys.
        // Arrow legends appear on these keys on Lisa and pre-ADB Mac keyboards.
        // KP 2 4 6 8 as arrow keys was exclusively an IBM PC thing.
        // ------------------------------------------------------------
        lisa_keycode_hid[8'h52] = 8'h27; // Up    -> KP / (Up in LisaTerminal)
        lisa_keycode_hid[8'h50] = 8'h22; // Left  -> KP + (Left in LisaTerminal)
        lisa_keycode_hid[8'h4F] = 8'h23; // Right -> KP * (Right in LisaTerminal)
        lisa_keycode_hid[8'h51] = 8'h2B; // Down  -> KP , (Down in LisaTerminal)

        // ------------------------------------------------------------
        // Nav cluster mapping from LisaKeys keyboard adapter
        // (https://github.com/RebeccaRGB/lisakeys)
        // ------------------------------------------------------------
        lisa_keycode_hid[8'h49] = 8'h46; // Ins  -> third Enter key
        lisa_keycode_hid[8'h4A] = 8'h68; // Home -> ` ~
        lisa_keycode_hid[8'h4B] = 8'h42; // PgUp -> \ |
        lisa_keycode_hid[8'h4C] = 8'h45; // Del  -> Backspace
        lisa_keycode_hid[8'h4D] = 8'h43; // End  -> < >
        lisa_keycode_hid[8'h4E] = 8'h2B; // PgDn -> KP ,
    end


    // ==== Key-event FIFO ===================================================
    // Each PS/2 make/break arrives as an event (report pulse + key_code_in +
    // key_press_in). We map it to a Lisa keycode and queue it; the serial
    // machine below drains one byte per Lisa poll. Because every make and break
    // is an independent queued event, overlapping keys (rollover) can no longer
    // drop a release the way the old single held-key level did.
    localparam int FD = 16;                  // FIFO depth (power of two)
    logic [7:0] kfifo [0:FD-1];
    logic [4:0] wr_ptr;                      // 5th bit lets wr-rd measure fullness
    logic [4:0] rd_ptr;
    logic       caps_lock_state;
    logic       reset_seq;                   // set by serial FSM: reload ID seq
    logic       reset_seq_d;

    wire fifo_empty = (wr_ptr == rd_ptr);
    wire fifo_full  = ((wr_ptr - rd_ptr) >= 5'd16);

    // Map a HID usage (regular table code, modifier usages 0xE0-0xE6, or caps
    // 0x39) to its 7-bit Lisa keycode base (0 = no mapping / ignore).
    logic [7:0] lisa_base;
    always_comb begin
        case (key_code_in)
            8'hE1, 8'hE5: lisa_base = 8'h7E;   // Shift  (L/R)
            8'hE0:        lisa_base = 8'h7C;   // Left Option  (L Ctrl)
            8'hE4:        lisa_base = 8'h4E;   // Right Option (R Ctrl)
            8'hE2, 8'hE6: lisa_base = 8'h7F;   // Apple  (L/R Alt)
            8'h39:        lisa_base = 8'h7D;   // Caps Lock (special toggle below)
            default:      lisa_base = (key_code_in < 8'h80) ? lisa_keycode_hid[key_code_in[6:0]] : 8'h00;
        endcase
    end

    // Push side: runs every clk_sys (ungated) so it never misses the one-cycle
    // report pulse. Owns kfifo, wr_ptr and caps_lock_state.
    always_ff @(posedge clk_sys, negedge usbrst) begin
        if (!usbrst) begin
            // Power-up: preload the keyboard power-on ID sequence 0x80,0xBF.
            kfifo[0] <= 8'h80;
            kfifo[1] <= 8'hBF;
            wr_ptr <= 5'd2;
            caps_lock_state <= 1'b0;
            reset_seq_d <= 1'b0;
        end else begin
            reset_seq_d <= reset_seq;
            if (reset_seq && !reset_seq_d) begin
                // Lisa requested a reset: drop queued keys, reload the ID seq.
                kfifo[0] <= 8'h80;
                kfifo[1] <= 8'hBF;
                wr_ptr <= 5'd2;
                caps_lock_state <= 1'b0;
            end else if (report && !fifo_full) begin
                if (key_code_in == 8'h39) begin
                    // Caps Lock is a locking key: toggle on make only; the Lisa
                    // wants 0x7D with bit7 = the (pre-toggle) lock state.
                    if (key_press_in) begin
                        caps_lock_state <= ~caps_lock_state;
                        kfifo[wr_ptr[3:0]] <= {caps_lock_state, 7'h7D};
                        wr_ptr <= wr_ptr + 5'd1;
                    end
                end else if (lisa_base != 8'h00) begin
                    // bit7 = 1 on press (down), 0 on release (up).
                    kfifo[wr_ptr[3:0]] <= {key_press_in, lisa_base[6:0]};
                    wr_ptr <= wr_ptr + 5'd1;
                end
            end
        end
    end

    always_ff @(posedge clk_sys, negedge usbrst) begin
        if (!usbrst) begin
            kbd_state <= KBD_RESET;
            KBD_out <= 1'b1; // Release KBD_out
            kbd_in_pulse_counter <= 26'd0;
            kbd_bit_timer <= 10'd0;
            lisa_keycode <= 8'd0;
            rd_ptr <= 5'd0;
            reset_seq <= 1'b0;
        end else if (usbclk_en) begin
            reset_seq <= 1'b0;
            case (kbd_state)
                IDLE: begin
                    KBD_out <= 1'b1; // Release KBD_out
                    // In the idle state, wait for KBD_in to go low
                    if (!KBD_in_sync) begin
                        // When it does, go to the WAIT_FOR_HIGH state
                        kbd_state <= WAIT_FOR_HIGH;
                        // And start counting how long KBD_in is low
                        kbd_in_pulse_counter <= 26'd1;
                    end
                end
                WAIT_FOR_HIGH: begin
                    // We're waiting for KBD_in to go high again to see what the Lisa wants
                    kbd_in_pulse_counter <= kbd_in_pulse_counter + 1;
                    if (KBD_in_sync) begin
                        // KBD_in went high again, check how long it was low for
                        if (kbd_in_pulse_counter >= 26'd55000) begin
                            // KBD_in was low for about 5ms or more, Lisa is requesting a reset
                            kbd_state <= KBD_RESET;
                        end else if (kbd_in_pulse_counter >= 26'd200) begin
                            // KBD_in was low for at about 20us, Lisa wants a key update
                            if (!fifo_empty) begin
                                // Pop the next queued keycode and send it.
                                lisa_keycode <= kfifo[rd_ptr[3:0]];
                                rd_ptr <= rd_ptr + 5'd1;
                                kbd_state <= WAIT_TO_SEND;
                            end else begin
                                // Nothing queued, back to idle.
                                kbd_state <= IDLE;
                            end
                        end else begin
                            // KBD_in was low for an invalid time, go back to idle
                            kbd_state <= IDLE;
                        end
                        kbd_in_pulse_counter <= 26'd0;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                WAIT_TO_SEND: begin
                    // Wait for 40us (480 clock cycles at 12MHz) before sending
                    // Nope, just kidding, after some testing we actually want to wait for 21.545-ish us or 258 clocks
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd258) begin
                        // Time to send the start bit
                        kbd_state <= SEND_START_BIT;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_START_BIT: begin
                    // Send the start bit (KBD_out low for 16us)
                    // We'll actually do 15.7us to be slightly closer to what I've observed with an actual Apple keyboard
                    KBD_out <= 1'b0;
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        // Move to sending D4 once we've waited 16us
                        kbd_state <= SEND_D4;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_D4: begin
                    // Send the inversion of bit D4 of the Lisa keycode
                    KBD_out <= ~lisa_keycode[4];
                    // And then wait 15.7us before going onto the next bit
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        kbd_state <= SEND_D5;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                // Repeat for D5 and D6
                SEND_D5: begin
                    KBD_out <= ~lisa_keycode[5];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        kbd_state <= SEND_D6;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_D6: begin
                    KBD_out <= ~lisa_keycode[6];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        kbd_state <= SEND_D7;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_D7: begin
                    // D7 is a little different; it's held low for 30us instead of 15.7us
                    // And we're actually going to do 30.745us to match the real keyboard again
                    KBD_out <= ~lisa_keycode[7];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd369) begin
                        kbd_state <= SEND_D0;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                // And then we're back to 15.7us for D0-D3
                SEND_D0: begin
                    KBD_out <= ~lisa_keycode[0];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        kbd_state <= SEND_D1;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_D1: begin
                    KBD_out <= ~lisa_keycode[1];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        kbd_state <= SEND_D2;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_D2: begin
                    KBD_out <= ~lisa_keycode[2];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        kbd_state <= SEND_D3;
                        kbd_bit_timer <= 10'd0;
                    end
                end
                SEND_D3: begin
                    KBD_out <= ~lisa_keycode[3];
                    kbd_bit_timer <= kbd_bit_timer + 1;
                    if (kbd_bit_timer >= 10'd188) begin
                        // Finished sending all bits, so go to FINISHED state
                        kbd_state <= FINISHED;
                        KBD_out <= 1'b1; // Release KBD_out
                    end
                end
                FINISHED: begin
                    // The only point of this state is to tell the decoder state machine when we're done sending a keycode
                    // So we just go back to idle here
                    kbd_state <= IDLE;
                end
                KBD_RESET: begin
                    // Flush the FIFO and reload 0x80,0xBF (the push side does the
                    // reload on the reset_seq edge); resync our read pointer.
                    reset_seq <= 1'b1;
                    rd_ptr <= 5'd0;
                    kbd_state <= IDLE;
                end
                default: begin
                    kbd_state <= IDLE;
                end
            endcase
        end
    end

endmodule