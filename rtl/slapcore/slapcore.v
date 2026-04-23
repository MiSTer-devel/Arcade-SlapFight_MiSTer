//============================================================================
//  Arcade: Slap Fight / Tiger Heli
//
//  Manufacturer: Toaplan
//          Type: Arcade Game
//         Genre: Vertical Shooter
//   Orientation: Vertical
//
//  Hardware Description by Anton Gale
//  https://github.com/MiSTer-devel/Arcade-SlapFight_MiSTer
//
//  This module implements the top-level FPGA core for both Slap Fight and
//  Tiger Heli arcade games. The pcb input selects between the two variants:
//    pcb=0: Slap Fight
//    pcb=1: Tiger Heli
//
//  Architecture Overview:
//  -  Main CPU: Z80A @ 6MHz - handles game logic, graphics control
//  - Audio CPU: Z80B @ 3MHz - handles sound generation
//  -     Sound: 2x AY-3-8910 (YM2149) @ 1.5MHz
//  -     Video: 256x224 @ 60Hz, 3 layers (foreground, sprites, background)
//  -    Colors: 256 colors from palette PROMs
//
//============================================================================
`timescale 1ns/1ps

module slapfight_fpga(
	input         clkm_48MHZ,       // Master clock (48 MHz)
	input         pcb,              // PCB select: 0=Slap Fight, 1=Tiger Heli
	input         flip,             // Flip video
	output  [3:0] RED,              // Red color output to video DAC
	output  [3:0] GREEN,            // Green color output to video DAC
	output  [3:0] BLUE,             // Blue color output to video DAC
	output        core_pix_clk,     // Pixel clock output (directly from internal pixel_clk)
	output        H_SYNC,           // Horizontal sync signal (directly from LINE_CLK)
	output        V_SYNC,           // Vertical sync signal (from ROM15 output)
	output        H_BLANK,          // Horizontal blanking signal
	output        V_BLANK,          // Vertical blanking signal (from LINE_CLK2)
	input         RESET_n,          // Active-low system reset
	input         pause,            // Pause control from MiSTer framework
	input   [8:0] CONTROLS,         // Player controls from MiSTer framework
	input   [7:0] DIP1,             // DIP switch bank 1
	input   [7:0] DIP2,             // DIP switch bank 2
	input  [24:0] dn_addr,          // ROM download address from MiSTer
	input         dn_wr,            // ROM download write enable
	input   [7:0] dn_data,          // ROM download data
	output signed [15:0] audio_l,   // Left audio output (directly from audio_snd or muted)
	output signed [15:0] audio_r,   // Right audio output (directly from audio_snd or muted)
	input  [15:0] hs_address,       // Hi-score RAM address
	output  [7:0] hs_data_out,      // Hi-score RAM data output
	input   [7:0] hs_data_in,       // Hi-score RAM data input
	input         hs_write          // Hi-score RAM write enable
);

//============================================================================
// Video Timing Registers and Counters
//============================================================================
reg   [7:0] VPIX;                   // Vertical pixel position (optionally flipped)
reg   [7:0] VSCRL_sum_in;           // Vertical scroll offset value
reg  [11:0] VCNT;                   // Vertical line counter (12-bit for extended range)
wire  [7:0] VSCRL;                  // Combined vertical scroll position

reg  [11:0] HPIX;                   // Horizontal pixel counter
reg   [8:0] HSCRL;                  // Horizontal scroll register (9-bit)
reg   [8:0] HPIXSCRL;               // Combined horizontal scroll position

reg         LINE_CLK2;              // Vertical blank signal (directly from ROM15[1] latched on H_SYNC)
wire        RESET_H_COUNTERS;       // Horizontal counter reset (directly from ROM14[3])
wire        RESET_V_COUNTERS;       // Vertical counter reset (directly from ROM15[3])
reg         IO2_SF;

//============================================================================
// Clock Generation
// All clocks derived from 48MHz master using clock enable technique
// This avoids clock domain crossing issues while maintaining timing accuracy
//============================================================================
reg clkm_24MHZ;                     // 24 MHz clock enable (48/2)
reg clkm_12MHZ;                     // 12 MHz clock enable (48/4)
reg clkm_3MHZ;                      // 3 MHz clock enable for audio CPU positive edge
reg clkm_6MHZ;                      // 6 MHz clock enable for main CPU positive edge
reg clk2_6MHZ;                      // 6 MHz clock enable phase 2
reg clk3_6MHZ;                      // 6 MHz clock enable phase 3
reg clkb_6MHZ;                      // 6 MHz clock enable for main CPU negative edge
reg clkb_3MHZ;                      // 3 MHz clock enable for audio CPU negative edge
reg clkc_6MHZ;                      // 6 MHz clock enable (duplicate of clkm_6MHZ)

reg [4:0] cencnt = 5'd0;            // Clock enable counter (0-31)

// Clock enable counter - increments every 48MHz cycle
always @(posedge clkm_48MHZ) begin
	cencnt <= cencnt + 5'd1;
end

// Generate all clock enables from counter phases
// Each clock enable is a single-cycle pulse at the appropriate division
always @(posedge clkm_48MHZ) begin
	clkm_24MHZ <= (cencnt[0]   == 1'd0);      // Every 2 cycles = 24 MHz
	clkm_12MHZ <= (cencnt[1:0] == 2'd0);      // Every 4 cycles = 12 MHz
	clkm_6MHZ  <= (cencnt[2:0] == 3'd0);      // Every 8 cycles = 6 MHz
	clkc_6MHZ  <= (cencnt[2:0] == 3'd0);      // Duplicate 6 MHz enable
	clk2_6MHZ  <= (cencnt[2:0] == 3'd1);      // 6 MHz phase 2
	clk3_6MHZ  <= (cencnt[2:0] == 3'd2);      // 6 MHz phase 3
	clkb_6MHZ  <= (cencnt[2:0] == 3'd4);      // 6 MHz negative edge (180° offset)
	clkm_3MHZ  <= (cencnt[3:0] == 4'd2);      // Every 16 cycles = 3 MHz (offset by 2)
	clkb_3MHZ  <= (cencnt[3:0] == 4'd10);     // 3 MHz negative edge
	ayclk_1p5M <= (cencnt[4:0] == 5'd4);      // Every 32 cycles = 1.5 MHz (offset to allow CPU settling)
	clk_6M_1   <= (cencnt[2:0] == 3'd0);      // 6 MHz for sprite layer
	pixel_clk  <= (cencnt[2:0] == 3'd2);      // Pixel clock (6 MHz, offset)
	clk_6M_3   <= (cencnt[2:0] == 3'd4);      // 6 MHz phase 3 for sprite line buffer
end

//============================================================================
// Vertical Counter and Timing
// VCNT counts lines, VPIX is the screen-relative position (flipped if IO2_SF)
// ROM15 provides vertical timing signals including VSYNC and VBLANK
//============================================================================
//always @(posedge LINE_CLK) begin
//	VCNT <= (!RESET_V_COUNTERS) ? 12'b0 : VCNT + 1;
//	VPIX <= (IO2_SF) ? (8'hFF ^ VCNT[7:0]) : VCNT[7:0];  // XOR for screen flip
//end

reg LINE_CLK_prev;
always @(posedge clkm_48MHZ) begin
    LINE_CLK_prev <= LINE_CLK;
    if (LINE_CLK && !LINE_CLK_prev) begin  // Rising edge detect
		VCNT <= (!RESET_V_COUNTERS) ? 12'b0 : VCNT + 1;
		VPIX <= (IO2_SF) ? (8'hFF ^ VCNT[7:0]) : VCNT[7:0];  // XOR for screen flip
    end
end

// Vertical timing ROM - generates reset and sync signals based on line count
wire [3:0] ROM15_out;
ROM15 U8B_ROM15(
	.clk(clkm_48MHZ),
	.addr(VCNT[8:1]),                         // 8-bit address from line counter
	.data({RESET_V_COUNTERS, ROM15_out[2:0]}) // Bit 3 = reset, bits 2:0 = timing
);

//============================================================================
// Screen Flip Logic
// IO2_SF controls 180° screen rotation for cocktail cabinet mode
//============================================================================
wire       IO2_SF_n   = ~IO2_SF;
wire [3:0] IO2_SF_rep = {4{IO2_SF_n}};        // Replicated for nibble operations
localparam signed [8:0] V_POS_OFF_NORMAL = 9'sd16;
localparam signed [8:0] V_POS_OFF_FLIP   = 9'sd8;
wire signed [9:0] VPIX_s                 = $signed({1'b0, VPIX});
wire signed [9:0] VPIX_OFF_s             = VPIX_s + (IO2_SF ? -$signed(V_POS_OFF_FLIP) : $signed(V_POS_OFF_NORMAL));
wire        [7:0] VPIX_OFF               = VPIX_OFF_s[7:0];

//============================================================================
// Vertical Scroll Register
// Written by main CPU to control background vertical scroll position
// In Tiger Heli mode (pcb=1), lower nibble is replaced with flip state
//============================================================================
always @(posedge V_SCRL_SEL) begin
	VSCRL_sum_in[7:4] <= Z80A_databus_out[7:4];
	VSCRL_sum_in[3:0] <= pcb ? IO2_SF_rep : Z80A_databus_out[3:0];
end

// Latch LINE_CLK2 (VBLANK indicator) on horizontal sync
always @(posedge H_SYNC) begin
	LINE_CLK2 <= ROM15_out[1];
end

//============================================================================
// Main CPU Interrupt Generation
// Edge-triggered interrupt on CPU_RAM_SELECT falling edge
// Cleared when INT_ENABLE is low
//============================================================================
reg Z80M_INT_n;
reg CPU_RAM_SELECT_prev;

always @(posedge clkm_48MHZ or negedge RESET_n) begin
	if (!RESET_n) begin
		Z80M_INT_n <= 1'b1;                    // Inactive (high)
		CPU_RAM_SELECT_prev <= 1'b1;
	end else begin
		CPU_RAM_SELECT_prev <= CPU_RAM_SELECT;
		
		if (!INT_ENABLE)
			Z80M_INT_n <= 1'b1;                // Clear interrupt
		else if (CPU_RAM_SELECT_prev && !CPU_RAM_SELECT)
			Z80M_INT_n <= 1'b0;                // Set interrupt on falling edge
	end
end

assign Z80M_INT = Z80M_INT_n;

// Final vertical scroll = pixel position + scroll offset
assign VSCRL = VPIX_OFF + VSCRL_sum_in;

//============================================================================
// Horizontal Counter and Timing
// HPIX counts pixels, direction depends on screen flip
// ROM14 provides horizontal timing signals including HSYNC and HBLANK
//============================================================================
always @(posedge pixel_clk) begin
	if (!RESET_H_COUNTERS) begin
		// Initialize to flip-dependent start position
		HPIX <= {3'b000, IO2_SF, 2'b00, IO2_SF, 2'b00, IO2_SF, IO2_SF, IO2_SF};
	end else begin
		HPIX <= (IO2_SF) ? HPIX - 1 : HPIX + 1;  // Count direction based on flip
	end
end

// Horizontal timing ROM
wire [3:0] ROM14_out;
ROM14 U2C_ROM14(
	.clk(clkm_48MHZ),
	.addr({IO2_SF, HPIX[8:2]}),               // 8-bit address includes flip state
	.data({RESET_H_COUNTERS, ROM14_out[2:0]})
);

//============================================================================
// Screen Flip and Horizontal Scroll Registers
//============================================================================
reg io_sf_reg;                                   // Screen flip enable
reg U1C_15;                                   // Horizontal blank timing
reg LINE_CLK;                                 // Horizontal sync (directly from ROM14)

reg flip_s1, flip_s2;
always @(posedge clkm_48MHZ or negedge RESET_n) begin
  if (!RESET_n) begin
    flip_s1 <= 1'b0;
    flip_s2 <= 1'b0;
  end else begin
    flip_s1 <= flip;
    flip_s2 <= flip_s1;
  end
end
wire flip_sync = flip_s2;

reg line_clk2_d;
reg flip_lat;

always @(posedge clkm_48MHZ or negedge RESET_n) begin
  if (!RESET_n) begin
    line_clk2_d <= 1'b0;
    flip_lat    <= 1'b0;
    IO2_SF      <= 1'b0;
  end else begin
    line_clk2_d <= LINE_CLK2;

    if (!line_clk2_d && LINE_CLK2) begin
      flip_lat <= flip_sync;
      IO2_SF <= io_sf_reg ^ flip_sync;
    end
  end
end

// Initialize screen flip from DIP switch on reset
// Different DIP bit used for Tiger Heli vs Slap Fight
always @(posedge clkm_48MHZ or negedge RESET_n) begin
  if (!RESET_n)
    io_sf_reg <= 1'b0;
  else
    io_sf_reg <= (pcb) ? DIP1[5] : DIP1[6];
end

// Horizontal scroll registers - directly from CPU databus
always @(posedge H_SCRL_LO_SEL) HSCRL[7:0] <= Z80A_databus_out;     // Low byte
always @(posedge H_SCRL_HI_SEL) HSCRL[8]   <= Z80A_databus_out[0];  // High bit

// Pipeline horizontal scroll calculation and timing signals
reg [8:0] HPIX_r, HSCRL_r;
always @(posedge clkm_48MHZ) begin
    if (pixel_clk) begin
        HPIX_r <= HPIX[8:0];
        HSCRL_r <= HSCRL[8:0];
		  HPIXSCRL <= HPIX_r + HSCRL_r;  // Uses OLD values of HPIX_r/HSCRL_r
		  U1C_15   <= ROM14_out[1];                 // HBLANK timing
		  LINE_CLK <= !ROM14_out[0];                // HSYNC (directly from ROM14)		  
    end
	 
	//HPIXSCRL <= HPIX[8:0] + HSCRL[8:0];       // Combined scroll position

end

//============================================================================
// CPU/Video RAM Synchronization
// Controls when CPU can access video RAM without causing display glitches
//============================================================================
wire CPU_RAM_SELECT = (!LINE_CLK2 & IO_4_CPU_RAM);	//Display sprites when paused
wire CPU_RAM_SYNC   = U1C_15 | !IO_4_CPU_RAM | !CPU_RAM_SELECT;
wire CPU_RAM_LBUF   = U1C_15;

//============================================================================
// Unused Registers (kept for compatibility/future use)
//============================================================================
reg [7:0] V_SCRL;                             // Unused - vertical scroll storage
reg [7:0] MCU_PORT;                           // Unused - MCU communication port

//============================================================================
// Graphics Layer Outputs
//============================================================================
wire [7:0] FG_PX_D;                           // Foreground pixel data
wire [8:0] HPIX_LT;                           // Latched HPIX for sprite timing

//============================================================================
// ROM Download Address Decoder
// Generates chip select signals for loading ROMs into BRAM during initialization
//============================================================================
wire ep0_cs_i, ep0b_cs_i, ep1_cs_i, ep2_cs_i;
wire ep3_cs_i, ep4_cs_i, ep5_cs_i, ep6_cs_i;
wire ep7_cs_i, ep8_cs_i, ep9_cs_i, ep10_cs_i;
wire ep11_cs_i, ep12_cs_i, ep13_cs_i, ep_dummy_cs_i;
wire cp1_cs_i, cp2_cs_i, cp3_cs_i;

selector DLSEL(
	.ioctl_addr(dn_addr),
	.ep0_cs(ep0_cs_i),                        // Main CPU ROM 0 (0x0000-0x3FFF)
	.ep0b_cs(ep0b_cs_i),                      // Main CPU ROM 0b (Tiger Heli addition)
	.ep1_cs(ep1_cs_i),                        // Main CPU ROM 1 (0x8000-0xBFFF, banked)
	.ep2_cs(ep2_cs_i),                        // Audio CPU ROM
	.ep3_cs(ep3_cs_i),                        // Foreground tile ROM
	.ep4_cs(ep4_cs_i),                        // Foreground tile ROM
	.ep5_cs(ep5_cs_i),                        // Background tile ROM
	.ep6_cs(ep6_cs_i),                        // Background tile ROM
	.ep7_cs(ep7_cs_i),                        // Background tile ROM
	.ep8_cs(ep8_cs_i),                        // Background tile ROM
	.ep9_cs(ep9_cs_i),                        // Sprite ROM
	.ep10_cs(ep10_cs_i),                      // Sprite ROM
	.ep11_cs(ep11_cs_i),                      // Sprite ROM
	.ep12_cs(ep12_cs_i),                      // Sprite ROM
	.ep13_cs(ep13_cs_i),                      // Unused
	.ep_dummy_cs(ep_dummy_cs_i),              // Unused
	.cp1_cs(cp1_cs_i),                        // Red color PROM
	.cp2_cs(cp2_cs_i),                        // Blue color PROM
	.cp3_cs(cp3_cs_i)                         // Green color PROM
);

//============================================================================
// Foreground Layer
// 2bpp text/status layer, highest priority, no scrolling
//============================================================================
foreground_layer slap_foreground(
	.reset_n(RESET_n),
	.master_clk(clkm_48MHZ),
	.pixel_clk(pixel_clk),
	.VPIX(VPIX_OFF),
	.HPIX(HPIX[8:0]),
	.SCREEN_FLIP(IO2_SF),
	.ATRRAM(ATRRAM),                          // Attribute RAM select
	.CHARAM(CHARAM),                          // Character RAM select
	.Z80_WR(Z80_WR),
	.CPU_ADDR(Z80A_addrbus),
	.CPU_DIN(Z80A_databus_out),
	.CPU_RAM_SYNC(CPU_RAM_SYNC),
	.dn_addr(dn_addr),
	.dn_data(dn_data),
	.ep3_cs_i(ep3_cs_i),
	.ep4_cs_i(ep4_cs_i),
	.dn_wr(dn_wr),
	.HPIX_LT_out(HPIX_LT),
	.FG_HI_out(FG_HI_out),
	.FG_LO_out(FG_LO_out),
	.pixel_output(FG_PX_D),
	.FG_WAIT(FG_WAIT)
);

//============================================================================
// Background Layer
// 4bpp scrolling tile layer, lowest priority
//============================================================================
background_layer slap_background(
	.reset_n(RESET_n),
	.master_clk(clkm_48MHZ),
	.pixel_clk(pixel_clk),
	.pcb(pcb),
	.VPIXSCRL(VSCRL),
	.HPIXSCRL(flip ? HPIXSCRL - 8'd16 : HPIXSCRL),
	.SCREEN_FLIP(IO2_SF),
	.BACKGRAM_1(BACKGRAM_1),
	.BACKGRAM_2(BACKGRAM_2),
	.Z80_WR(Z80_WR),
	.CPU_RAM_SYNC(CPU_RAM_SYNC),
	.CPU_ADDR(Z80A_addrbus),
	.CPU_DIN(Z80A_databus_out),
	.dn_addr(dn_addr),
	.dn_data(dn_data),
	.ep5_cs_i(ep5_cs_i),
	.ep6_cs_i(ep6_cs_i),
	.ep7_cs_i(ep7_cs_i),
	.ep8_cs_i(ep8_cs_i),
	.dn_wr(dn_wr),
	.BG_HI_out(BG_HI_out),
	.BG_LO_out(BG_LO_out),
	.pixel_output(BG_PX_D),
	.BG_WAIT(BG_WAIT)
);

//============================================================================
// Sprite Layer
// 4bpp sprite layer with line buffer, middle priority
//============================================================================
sprite_layer slap_sprites(
	.reset_n(RESET_n),
	.master_clk(clkm_48MHZ),
	.pixel_clk(pixel_clk),
	.npixel_clk(clk_6M_1),
	.pixel_clk_lb(clk_6M_3),
	.VPIX(VPIX_OFF),
	.HPIX(HPIX),
	.HPIX_LT(HPIX_LT),
	.SCREEN_FLIP(IO2_SF),
	.SPRITE_RAM(SPRITE_RAM),
	.Z80_WR(Z80_WR),
	.Z80_RD(Z80_RD),
	.CPU_ADDR(Z80A_addrbus),
	.CPU_DIN(Z80A_databus_out),
	.CPU_RAM_SYNC(CPU_RAM_SYNC),
	.CPU_RAM_SELECT(CPU_RAM_SELECT),
	.CPU_RAM_LBUF(CPU_RAM_LBUF),
	.dn_addr(dn_addr),
	.dn_data(dn_data),
	.ep9_cs_i(ep9_cs_i),
	.ep10_cs_i(ep10_cs_i),
	.ep11_cs_i(ep11_cs_i),
	.ep12_cs_i(ep12_cs_i),
	.dn_wr(dn_wr),
	.SP_RAMD_out(SP_RAMD_out),
	.pixel_output(SP_PX_D)
);

// Graphics layer RAM data outputs
wire [7:0] FG_HI_out, FG_LO_out;              // Foreground RAM readback
wire [7:0] BG_HI_out, BG_LO_out;              // Background RAM readback
wire [7:0] SP_RAMD_out;                       // Sprite RAM readback

//============================================================================
// Additional Clock Enables
//============================================================================
reg ayclk_1p5M;                               // AY sound chip clock enable (1.5 MHz)
reg clk_6M_1, pixel_clk, clk_6M_3;           // Pixel timing clock enables

assign core_pix_clk = pixel_clk;

wire PUR = 1'b1;                              // Active high pull-up (directly high)

//============================================================================
// Main CPU (Z80A) Bus Definitions
//============================================================================
wire [15:0] Z80A_addrbus;                     // Main CPU address bus
wire  [7:0] Z80A_databus_in;                  // Main CPU data bus input
wire  [7:0] Z80A_databus_out;                 // Main CPU data bus output
wire        Z80_MREQ;                         // Memory request (active low)
wire        Z80_WR;                           // Write strobe (active low)
wire        Z80_RD;                           // Read strobe (active low)
wire        Z80M_IOREQ;                       // I/O request (active low)
wire        Z80M_INT;                         // Interrupt request (active low)
wire  [7:0] U8M_Z80M_RAM_out;                 // Main CPU work RAM output

// Audio CPU bus definitions
wire [15:0] AUA;                              // Audio address bus (directly from AUA mux)
wire [15:0] CPU_AUA;                          // Audio CPU address output
wire  [7:0] AUD_in;                           // Audio CPU data bus input
wire  [7:0] AUD_out;                          // Audio CPU data bus output
wire        AUIMREQ;                          // Audio memory request
wire        AUWR;                             // Audio write strobe
wire        AURD;                             // Audio read strobe

//============================================================================
// Main CPU (Z80A) - 6 MHz
// Handles game logic, video control, and player input
//============================================================================
T80pa Z80A(
	.RESET_n(RESET_n),
	.WAIT_n(wait_n),
	.INT_n(Z80M_INT),
	.BUSRQ_n(PUR),                            // No bus request
	.NMI_n(PUR),                              // No NMI
	.CLK(clkm_48MHZ),
	.CEN_p(clkm_6MHZ & !pause_safe),          // Positive edge enable
	.CEN_n(clkb_6MHZ & !pause_safe),          // Negative edge enable
	.MREQ_n(Z80_MREQ),
	.IORQ_n(Z80M_IOREQ),
	.DI(Z80A_databus_in),
	.DO(Z80A_databus_out),
	.A(Z80A_addrbus),
	.WR_n(Z80_WR),
	.RD_n(Z80_RD)
);

// MCU handshake signals (directly from U7A flip-flops)
wire RD_BUFFER_FULL_68705, WR_BUFFER_FULL_68705;

//============================================================================
// Main CPU Memory Map Decoding
// All active-low chip selects using OR-gate decode pattern
// Output is low when MREQ is low AND address matches
//============================================================================
wire SEL_ROM0A      = Z80_MREQ |  Z80A_addrbus[15] |  Z80A_addrbus[14];  // 0x0000-0x3FFF
wire SEL_ROM0B      = Z80_MREQ |  Z80A_addrbus[15] | ~Z80A_addrbus[14];  // 0x4000-0x7FFF
wire SEL_ROM1       = Z80_MREQ | ~Z80A_addrbus[15] |  Z80A_addrbus[14];  // 0x8000-0xBFFF
wire SEL_Z80M_RAM   = Z80_MREQ | ~Z80A_addrbus[15] | ~Z80A_addrbus[14] |  Z80A_addrbus[13] |  Z80A_addrbus[12] |  Z80A_addrbus[11];  // 0xC000-0xC7FF
wire AUDIO_CPU_PORT = Z80_MREQ | ~Z80A_addrbus[15] | ~Z80A_addrbus[14] |  Z80A_addrbus[13] |  Z80A_addrbus[12] | ~Z80A_addrbus[11];  // 0xC800-0xCFFF
wire BACKGRAM_1     = Z80_MREQ | ~Z80A_addrbus[15] | ~Z80A_addrbus[14] |  Z80A_addrbus[13] | ~Z80A_addrbus[12] |  Z80A_addrbus[11];  // 0xD000-0xD7FF
wire BACKGRAM_2     = Z80_MREQ | ~Z80A_addrbus[15] | ~Z80A_addrbus[14] |  Z80A_addrbus[13] | ~Z80A_addrbus[12] | ~Z80A_addrbus[11];  // 0xD800-0xDFFF
wire SPRITE_RAM     = Z80_MREQ | ~Z80A_addrbus[15] | ~Z80A_addrbus[14] | ~Z80A_addrbus[13] |  Z80A_addrbus[12] |  Z80A_addrbus[11];  // 0xE000-0xE7FF
wire SEL_MCU_PORT   = Z80_MREQ | ~Z80A_addrbus[15] | ~Z80A_addrbus[14] | ~Z80A_addrbus[13] |  Z80A_addrbus[12] | ~Z80A_addrbus[11];  // 0xE800-0xEFFF
wire CHARAM         = Z80_MREQ | ~Z80A_addrbus[15] | ~Z80A_addrbus[14] | ~Z80A_addrbus[13] | ~Z80A_addrbus[12] |  Z80A_addrbus[11];  // 0xF000-0xF7FF
wire ATRRAM         = Z80_MREQ | ~Z80A_addrbus[15] | ~Z80A_addrbus[14] | ~Z80A_addrbus[13] | ~Z80A_addrbus[12] | ~Z80A_addrbus[11];  // 0xF800-0xFFFF

//============================================================================
// Main CPU Data Bus Read Multiplexer
// One-hot OR pattern for efficient timing - all selects are mutually exclusive
//============================================================================
assign Z80A_databus_in = 
	({8{!Z80_RD & !SEL_ROM0A}}                    & prom_prog1_out)   |  // Program ROM 1
	({8{!Z80_RD & !SEL_ROM0B}}                    & prom_prog1b_out)  |  // Program ROM 1b (Tiger Heli)
	({8{!Z80_RD & !SEL_ROM1}}                     & prom_prog2_out)   |  // Program ROM 2 (banked)
	({8{!Z80_RD & !Z80M_IOREQ}}                   & {7'b0, LINE_CLK2})|  // I/O read: VBLANK status
	({8{!Z80_RD & !SEL_Z80M_RAM}}                 & U8M_Z80M_RAM_out) |  // Work RAM
	({8{!Z80_RD & !CHARAM}}                       & FG_LO_out)        |  // Foreground char RAM
	({8{!Z80_RD & !ATRRAM}}                       & FG_HI_out)        |  // Foreground attr RAM
	({8{!Z80_RD & !BACKGRAM_1}}                   & BG_LO_out)        |  // Background RAM low
	({8{!Z80_RD & !BACKGRAM_2}}                   & BG_HI_out)        |  // Background RAM high
	({8{!Z80_RD & !SPRITE_RAM}}                   & SP_RAMD_out)      |  // Sprite RAM
	({8{!Z80_RD & !AUDIO_CPU_PORT & !AU_RAM_CS}} & AUDIO_RAMM_out);     // Shared audio RAM

//============================================================================
// Wait State Generation
// Main CPU waits for audio handshake and video timing (Tiger Heli mode)
//============================================================================
wire FG_WAIT, BG_WAIT;
wire wait_n = !pause & AU_WAIT & ((FG_WAIT & BG_WAIT) | pcb);

//============================================================================
// Audio Handshake Wait Logic
// Freezes during pause to prevent state corruption
//============================================================================
reg AU_RDY, AU_RDY2;
wire pause_audio = pause;

always @(posedge clkm_48MHZ) begin
	if (clkm_6MHZ && !pause_audio) begin
		AU_RDY2 <= AUDIOM_OK;
		AU_RDY  <= !AUDIOM_OK;
	end
end

wire AU_WAIT = AUDIO_CPU_PORT | AU_RDY | !AU_ENABLE;

//============================================================================
// MCU Port Register Decoding (0xE800-0xE803)
// Active-low outputs using OR-gate decode pattern
//============================================================================
wire MCU_EN        = SEL_MCU_PORT | Z80_WR;
wire H_SCRL_LO_SEL = MCU_EN |  Z80A_addrbus[1] |  Z80A_addrbus[0];  // 0xE800: H scroll low
wire H_SCRL_HI_SEL = MCU_EN |  Z80A_addrbus[1] | ~Z80A_addrbus[0];  // 0xE801: H scroll high
wire V_SCRL_SEL    = MCU_EN | ~Z80A_addrbus[1] |  Z80A_addrbus[0];  // 0xE802: V scroll
wire MCU_PORT_WR   = MCU_EN | ~Z80A_addrbus[1] | ~Z80A_addrbus[0];  // 0xE803: MCU port

//============================================================================
// I/O Port Registers (directly from Z80 I/O writes)
// Written via I/O port addresses 0x00-0x0F
// Each register stores bit 0 of the address as data
//============================================================================
reg RESET_68705;                              // MCU reset control
reg IO_C_SPRITE_COLOUR;                       // Sprite color bank select
reg U9J_Q5;                                   // Unused register
reg SEL_ROM_BANK_SH;                          // ROM bank select
reg INT_ENABLE;                               // Interrupt enable
reg IO_4_CPU_RAM;                             // CPU RAM access enable
reg AU_ENABLE;                                // Audio CPU enable
reg IO2_SFx;                                  // Unused flip register

wire IO_WR_EN = Z80M_IOREQ | Z80_WR;
reg IO_WR_EN_prev;

// Edge-triggered I/O register updates
always @(posedge clkm_48MHZ or negedge RESET_n) begin
	if (!RESET_n) begin
		AU_ENABLE          <= 1'b0;
		IO2_SFx            <= 1'b0;
		IO_4_CPU_RAM       <= 1'b0;
		INT_ENABLE         <= 1'b0;
		SEL_ROM_BANK_SH    <= 1'b0;
		U9J_Q5             <= 1'b0;
		IO_C_SPRITE_COLOUR <= 1'b0;
		RESET_68705        <= 1'b0;
		IO_WR_EN_prev      <= 1'b1;
	end else begin
		IO_WR_EN_prev <= IO_WR_EN;
		
		// Capture on falling edge of I/O write strobe
		if (IO_WR_EN_prev && !IO_WR_EN) begin
			case (Z80A_addrbus[3:1])
				3'b000: AU_ENABLE          <= Z80A_addrbus[0];  // Port 0x00/0x01
				3'b001: IO2_SFx            <= Z80A_addrbus[0];  // Port 0x02/0x03
				3'b010: IO_4_CPU_RAM       <= Z80A_addrbus[0];  // Port 0x04/0x05
				3'b011: INT_ENABLE         <= Z80A_addrbus[0];  // Port 0x06/0x07
				3'b100: SEL_ROM_BANK_SH    <= Z80A_addrbus[0];  // Port 0x08/0x09
				3'b101: U9J_Q5             <= Z80A_addrbus[0];  // Port 0x0A/0x0B
				3'b110: IO_C_SPRITE_COLOUR <= Z80A_addrbus[0];  // Port 0x0C/0x0D
				3'b111: RESET_68705        <= Z80A_addrbus[0];  // Port 0x0E/0x0F
			endcase
		end
	end
end



//============================================================================
// Main CPU Work RAM (2KB)
// Dual-port for hi-score save/load functionality
//============================================================================
dpram_dc #(.widthad_a(11)) U8M_Z80M_RAM(
	.clock_a(clkm_48MHZ),
	.address_a(Z80A_addrbus[10:0]),
	.data_a(Z80A_databus_out),
	.wren_a(!Z80_WR & !SEL_Z80M_RAM),
	.q_a(U8M_Z80M_RAM_out),
	
	.clock_b(clkm_48MHZ),
	.address_b(hs_address[10:0]),
	.data_b(hs_data_in),
	.wren_b(hs_write),
	.q_b(hs_data_out)
);

//============================================================================
// Main CPU Program ROMs
//============================================================================
wire [7:0] prom_prog1_out;
wire [7:0] prom_prog1b_out;
wire [7:0] prom_prog2_out;

// ROM 0: 0x0000-0x3FFF (16KB)
eprom_0 U8N_A77_00(
	.ADDR(Z80A_addrbus[13:0]),
	.CLK(clkm_48MHZ),
	.DATA(prom_prog1_out),
	.ADDR_DL(dn_addr),
	.CLK_DL(clkm_48MHZ),
	.DATA_IN(dn_data),
	.CS_DL(ep0_cs_i),
	.WR(dn_wr)
);

// ROM 0b: 0x4000-0x7FFF (Tiger Heli addition)
eprom_0b U8N_A77_00b(
	.ADDR(Z80A_addrbus[13:0]),
	.CLK(clkm_48MHZ),
	.DATA(prom_prog1b_out),
	.ADDR_DL(dn_addr),
	.CLK_DL(clkm_48MHZ),
	.DATA_IN(dn_data),
	.CS_DL(ep0b_cs_i),
	.WR(dn_wr)
);

// ROM 1: 0x8000-0xBFFF (16KB, banked via SEL_ROM_BANK_SH)
eprom_1 U8P_A77_01(
	.ADDR({SEL_ROM_BANK_SH, Z80A_addrbus[13:0]}),
	.CLK(clkm_48MHZ),
	.DATA(prom_prog2_out),
	.ADDR_DL(dn_addr),
	.CLK_DL(clkm_48MHZ),
	.DATA_IN(dn_data),
	.CS_DL(ep1_cs_i),
	.WR(dn_wr)
);

//============================================================================
// Sound System
//============================================================================
wire [7:0] AY_1_databus_out, AY_2_databus_out;  // AY chip data outputs
wire [9:0] sound_outF, sound_outV;              // AY analog outputs
wire [7:0] AUDIO_RAM_out, AUDIO_RAMM_out;       // Audio RAM outputs
wire       AY12F_sample;                        // AY sample strobe
wire       AUDIO_CPU_BUSACK;                    // Audio CPU bus acknowledge

//============================================================================
// Pause Synchronization
// Waits for audio bus to be idle before asserting pause
// Prevents handshake corruption on pause/unpause
//============================================================================
reg pause_sync;
reg pause_safe;

always @(posedge clkm_48MHZ or negedge RESET_n) begin
	if (!RESET_n) begin
		pause_sync <= 1'b0;
		pause_safe <= 1'b0;
	end else begin
		pause_sync <= pause;
		if (AUDIOM_OK)
			pause_safe <= pause_sync;
	end
end

//============================================================================
// Audio CPU (Z80B) - 3 MHz
// Dedicated sound processor controlling two AY-3-8910 chips
//============================================================================
T80pa Z80B(
	.RESET_n(AU_ENABLE),                      // Directly from I/O register
	.WAIT_n(!pause),
	.INT_n(PUR),                              // No INT
	.BUSRQ_n(AUDIO_CPU_PORT | pause_safe),    // Bus request from main CPU
	.NMI_n(AUDIO_CPU_NMI),                    // Periodic NMI from timer
	.CLK(clkm_48MHZ),
	.CEN_p(clkm_3MHZ & !pause_safe),
	.CEN_n(clkb_3MHZ & !pause_safe),
	.MREQ_n(AUIMREQ),
	.DI(AUD_in),
	.DO(AUD_out),
	.A(CPU_AUA),
	.WR_n(AUWR),
	.RD_n(AURD),
	.BUSAK_n(AUDIO_CPU_BUSACK)
);

// Audio bus ownership - main CPU can access when audio CPU releases bus
wire AUDIOM_OK = AUDIO_CPU_PORT | AUDIO_CPU_BUSACK | pause_safe;
assign AUA = (AUDIOM_OK) ? CPU_AUA : Z80A_addrbus;

//============================================================================
// Audio CPU Work RAM (2KB)
// Dual-port for main CPU access to shared sound commands
//============================================================================
dpram_dc #(.widthad_a(11)) S2_U11B(
	.clock_a(clkm_48MHZ),
	.address_a(CPU_AUA[10:0]),
	.data_a(AUD_out),
	.wren_a(!AUWR & !AU_RAM_CS & !pause_audio),
	.q_a(AUDIO_RAM_out),
	
	.clock_b(clkm_48MHZ),
	.address_b(Z80A_addrbus[10:0]),
	.data_b(Z80A_databus_out),
	.wren_b(!AUDIOM_OK & !Z80_WR & !pause_audio),
	.q_b(AUDIO_RAMM_out)
);

//============================================================================
// Player Controls (directly from MiSTer framework)
//============================================================================
wire m_right   = CONTROLS[0];
wire m_left    = CONTROLS[1];
wire m_down    = CONTROLS[2];
wire m_up      = CONTROLS[3];
wire m_shoot   = CONTROLS[4];
wire m_shoot2  = CONTROLS[5];
wire m_start1p = CONTROLS[6];
wire m_start2p = CONTROLS[7];
wire m_coin    = CONTROLS[8];

//============================================================================
// Audio CPU Memory Map Decoding
//============================================================================
reg [7:0] AY1_IOA_in, AY1_IOB_in;              // Unused AY I/O registers
reg [7:0] AY2_IOA_in, AY2_IOB_in;              // Unused AY I/O registers

// Address decoding using ternary (could be optimized to OR pattern)
wire AU_ROM_CS = (AUA[15:13] == 3'b000) ? 1'b0 : 1'b1;  // 0x0000-0x1FFF
wire AU_IO     = (AUA[15:13] == 3'b101) ? 1'b0 : 1'b1;  // 0xA000-0xBFFF
wire AU_RAM_CS = (AUA[15:13] == 3'b110) ? 1'b0 : 1'b1;  // 0xC000-0xDFFF

// Combined audio I/O request signal
wire COMB_AUIMREQ = (AUDIOM_OK | AU_RDY2) ? AUIMREQ : Z80M_IOREQ;
wire AU_IO_EN     = COMB_AUIMREQ | AU_IO;

// AY chip and interrupt select decoding
wire AY_2_SEL    = AU_IO_EN | (AUA[7:4] != 4'b1000);  // 0xA080-0xA08F
wire AY_1_SEL    = AU_IO_EN | (AUA[7:4] != 4'b1001);  // 0xA090-0xA09F
wire AUD_INT_SET = AU_IO_EN | (AUA[7:4] != 4'b1110);  // 0xA0E0-0xA0EF
wire AUD_INT_CLK = AU_IO_EN | (AUA[7:4] != 4'b1111);  // 0xA0F0-0xA0FF

//============================================================================
// Audio CPU Data Bus Read Multiplexer
//============================================================================
wire AU_RD_EN = !AURD;

assign AUD_in = 
	({8{AU_RD_EN & !AU_ROM_CS}} & S2_U12D_AU_A77_02_out) |  // Audio ROM
	({8{AU_RD_EN & !AU_RAM_CS}} & AUDIO_RAM_out)         |  // Audio RAM
	({8{AU_RD_EN & !AY_1_SEL}}  & AY_1_databus_out)      |  // AY chip 1
	({8{AU_RD_EN & !AY_2_SEL}}  & AY_2_databus_out);        // AY chip 2

//============================================================================
// AY-3-8910 Control Signal Generation
// BDIR and BC1 control read/write/address operations
//============================================================================
wire AY_1_BDIR = !(AUA[0] | AY_1_SEL);
wire AY_1_BC1  = !(AUA[1] | AY_1_SEL);
wire AY_2_BDIR = !(AUA[0] | AY_2_SEL);
wire AY_2_BC1  = !(AUA[1] | AY_2_SEL);

//============================================================================
// AY-3-8910 Sound Chip #1
// Handles DIP switch reading via I/O ports
//============================================================================
jt49_bus #(.COMP(2'b10)) AY_1_S2_U11G(
	.rst_n(AU_ENABLE),
	.clk(clkm_48MHZ),
	.clk_en(ayclk_1p5M),                       // 1.5 MHz clock enable
	.bdir(AY_1_BDIR),
	.bc1(AY_1_BC1),
	.din(AUD_out),
	.sel(1'b1),
	.dout(AY_1_databus_out),
	.sound(sound_outF),
	.A(), .B(), .C(),                          // Individual channels unused
	.sample(AY12F_sample),
	.IOA_in(DIP1),                             // DIP switch bank 1
	.IOB_in(DIP2)                              // DIP switch bank 2
);

//============================================================================
// AY-3-8910 Sound Chip #2
// Handles player control reading via I/O ports
//============================================================================
jt49_bus #(.COMP(2'b10)) AY_2_S2_11J(
	.rst_n(AU_ENABLE),
	.clk(clkm_48MHZ),
	.clk_en(ayclk_1p5M),
	.bdir(AY_2_BDIR),
	.bc1(AY_2_BC1),
	.din(AUD_out),
	.sel(1'b1),
	.dout(AY_2_databus_out),
	.sound(sound_outV),
	.A(), .B(), .C(),
	.sample(),
	.IOA_in({4'b1111, m_left, m_right, m_down, m_up}),     // Joystick
	.IOB_in({1'b1, m_coin, m_start2p, m_start1p, 2'b11, m_shoot, m_shoot2})  // Buttons
);

//============================================================================
// Audio Output Processing
// Combines both AY chips and applies DC offset filtering
//============================================================================
wire signed [15:0] audio_snd;

jtframe_jt49_filters u_filters(
	.rst(!AU_ENABLE),
	.clk(clkm_48MHZ),
	.din0(sound_outF),
	.din1(sound_outV),
	.sample(AY12F_sample),
	.dout(audio_snd)
);

// Mute audio during pause
assign audio_l = (pause) ? 16'b0 : audio_snd;
assign audio_r = (pause) ? 16'b0 : audio_snd;

//============================================================================
// Audio CPU Program ROM (8KB)
//============================================================================
wire [7:0] S2_U12D_AU_A77_02_out;

eprom_2 S2_U12D_AU_A77_02(
	.ADDR(CPU_AUA[12:0]),
	.CLK(clkm_48MHZ),
	.DATA(S2_U12D_AU_A77_02_out),
	.ADDR_DL(dn_addr),
	.CLK_DL(clkm_48MHZ),
	.DATA_IN(dn_data),
	.CS_DL(ep2_cs_i),
	.WR(dn_wr)
);

//============================================================================
// Audio CPU NMI Generation
// Periodic interrupt from timer, rate differs between games
//============================================================================
reg        AUDIO_CPU_NMI;
reg [13:0] U7A_TMR_out;
reg        AU_INT_ON = 1'b0;

wire nRST_AU = !AU_ENABLE | AU_INT_ON | !RESET_n;

// Initialize audio interrupt flag on reset
always @(posedge AUD_INT_CLK or negedge RESET_n) begin
	AU_INT_ON <= (!RESET_n) ? 1'b1 : 1'b0;
end

// NMI timer counter - pauses during game pause
always @(posedge clkm_48MHZ or posedge nRST_AU) begin
	if (nRST_AU)
		U7A_TMR_out <= 14'b0;
	else if (clkm_3MHZ && !pause)
		U7A_TMR_out <= U7A_TMR_out + 1;
end

// NMI output - different bit for each game variant
always @(*) begin
	AUDIO_CPU_NMI = (pcb) ? !U7A_TMR_out[12] : !U7A_TMR_out[13];
end

//============================================================================
// Pixel Priority and Color Output
// Priority: Foreground > Sprites > Background
// Color 0 in each layer is transparent
//============================================================================
wire [7:0] SP_PX_D;
wire [7:0] BG_PX_D;
reg  [7:0] COLOUR_REG;

always @(posedge pixel_clk or negedge RESET_n) begin
	if (!RESET_n) begin
		COLOUR_REG <= 8'b0;
	end else begin
		if (FG_PX_D[1:0] != 2'b00)
			COLOUR_REG <= FG_PX_D;              // Foreground visible (2bpp, non-zero)
		else if (SP_PX_D[3:0] != 4'b0000)
			COLOUR_REG <= SP_PX_D;              // Sprite visible (4bpp, non-zero)
		else
			COLOUR_REG <= BG_PX_D;              // Background (default)
	end
end

//============================================================================
// Color Palette PROMs
// Convert 8-bit palette index to 4-bit RGB components
//============================================================================
cprom_1 S2_U12Q(                              // Red PROM
	.ADDR(COLOUR_REG),
	.CLK(clkm_48MHZ),
	.DATA(RED),
	.ADDR_DL(dn_addr),
	.CLK_DL(clkm_48MHZ),
	.DATA_IN(dn_data),
	.CS_DL(cp1_cs_i),
	.WR(dn_wr)
);

cprom_2 S2_U12P(                              // Blue PROM
	.ADDR(COLOUR_REG),
	.CLK(clkm_48MHZ),
	.DATA(BLUE),
	.ADDR_DL(dn_addr),
	.CLK_DL(clkm_48MHZ),
	.DATA_IN(dn_data),
	.CS_DL(cp2_cs_i),
	.WR(dn_wr)
);

cprom_3 S2_U12N(                              // Green PROM
	.ADDR(COLOUR_REG),
	.CLK(clkm_48MHZ),
	.DATA(GREEN),
	.ADDR_DL(dn_addr),
	.CLK_DL(clkm_48MHZ),
	.DATA_IN(dn_data),
	.CS_DL(cp3_cs_i),
	.WR(dn_wr)
);

localparam [7:0] VWIN_T = 8'd0;
localparam [7:0] VWIN_B = 8'd223;
localparam signed [8:0] V_SHIFT = 9'sd0;
wire signed [9:0] V_Ts = $signed({1'b0, VWIN_T}) + $signed(V_SHIFT);
wire signed [9:0] V_Bs = $signed({1'b0, VWIN_B}) + $signed(V_SHIFT);
wire [7:0] V_T = V_Ts[7:0];
wire [7:0] V_B = V_Bs[7:0];
wire V_TRIM_BLANK = ($signed(VPIX_OFF_s) < $signed(V_Ts)) | ($signed(VPIX_OFF_s) > $signed(V_Bs));

//============================================================================
// Video Sync Signal Outputs
//============================================================================
assign H_SYNC  = LINE_CLK;                    // Horizontal sync (directly from timing ROM)
assign V_SYNC  = ROM15_out[0];                // Vertical sync (directly from timing ROM)
assign H_BLANK = U1C_15 | ((IO2_SF) ? (HPIX > 283) : (HPIX < 13));  // Blanking region
assign V_BLANK = LINE_CLK2;                   // Vertical blank (directly from latched ROM15)

endmodule