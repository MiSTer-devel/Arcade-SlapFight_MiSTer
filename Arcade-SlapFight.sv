//============================================================================
//  Arcade: Slap Fight
//
//  Manufacturer: Toaplan
//  Type: Arcade Game
//  Genre: Shooter
//  Orientation: Vertical
//
//  Hardware Description by Anton Gale
//  https://github.com/antongale/Arcade-SlapFight_MiSTer
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
wire [15:0] sdram_sz;
assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign VGA_DISABLE = 0;
assign FB_FORCE_BLANK = 0;

assign AUDIO_S = 1;  // Signed audio output
assign AUDIO_MIX = 3;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//============================================================================
// DIP Switch Loading
//============================================================================
reg [7:0] sw[8];

always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3]) begin
		sw[ioctl_addr[2:0]] <= ioctl_dout;
	end
end	

//============================================================================
// HPS I/O Interface
//============================================================================

wire [31:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire        direct_video;
wire        video_rotated;

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;
wire  [7:0] ioctl_index;
wire        ioctl_wait;

wire [15:0] joystick_0;

wire [21:0] gamma_bus;

//============================================================================
// Aspect Ratio Configuration
//============================================================================

wire [1:0] ar = status[30:29];

assign VIDEO_ARX = (!ar) ? ((status[2]) ? 12'd1132 : 12'd939) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? ((status[2]) ? 12'd939 : 12'd1132) : 12'd0;

//============================================================================
// Game Module Selection
//============================================================================

reg mod_slap  = 0;
reg mod_other = 0;

always @(posedge clk_sys) begin
	reg [7:0] mod = 0;
	if (ioctl_wr & (ioctl_index==1)) mod <= ioctl_dout;

	mod_slap  <= (mod == 0);
	mod_other <= (mod == 1);
end

//============================================================================
// OSD Configuration String
//============================================================================
// Status Bit Map:
//     0         1         2         3
//     01234567890123456789012345678901
//     0123456789ABCDEFGHIJKLMNOPQRSTUV
// AR:                            XX    (bits 30:29)
// OR:   X                              (bit 2)
// SD:    XXX                           (bits 5:3)
// FL:       X                          (bit 6) - Flip screen
// FQ:                              X   (bit 31) - Frequency select
// HS:                           X      (bit 28)
// PA:                      XX          (bits 26:25)

`include "build_id.v"
localparam CONF_STR = {
	"A.SLAPFIGHT;;",
	"OTU,Aspect ratio,Original,Full Screen;",
	"O2,Orientation,Vert,Horz;",
	"O6,Flip,Off,On;",
	"O35,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"OV,Frequency,Original,60Hz (Overclock);",
	"-;",
	"DIP;",
	"-;",
	"H1OS,Autosave Hiscores,Off,On;",
	"P1,Pause options;",
	"P1OP,Pause when OSD is open,On,Off;",
	"P1OQ,Dim video after 10s,On,Off;",
	"-;",
	"R0,Reset;",
	"J1,Fire,Weapon Select,Start 1P,Start 2P,Coin,Pause;",
	"V,v",`BUILD_DATE
};

wire        sd_buff_wr, img_readonly;
wire  [7:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din[2];
wire [15:0] sd_req_type;
wire [63:0] img_size;
wire [31:0] sd_lba[2];
wire  [1:0] sd_wr;
wire  [1:0] sd_rd;
wire  [1:0] sd_ack;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask({~hs_configured,direct_video}),
	.new_vmode(new_vmode),  
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0)
);

//============================================================================
// Clock Generation and PLL Reconfiguration
//============================================================================
// Two frequencies supported:
//   48.000000 MHz - For original arcade timing (~56.9Hz)
//   50.526315 MHz - For 60Hz display mode
//
// Formula: fout = fref × M / (N × C)
// Reference: 50 MHz, M = 96, N = 5, VCO = 960 MHz
//
// 48.000000 MHz = 50 × 96 / (5 × 20) = 960 / 20
// 50.526315 MHz = 50 × 96 / (5 × 19) = 960 / 19
//============================================================================

wire clkm_48MHZ;
wire clk_sys = clkm_48MHZ;
wire clk_vid = clk_sys;
wire pll_locked;

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clkm_48MHZ),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(pll_locked)
);

//============================================================================
// PLL Reconfiguration Controller
//============================================================================
wire        pll_waitrequest;
reg         pll_write = 0;
reg  [5:0]  pll_addr;
reg  [31:0] pll_data;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(pll_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(pll_write),
	.mgmt_writedata(pll_data),
	.mgmt_address(pll_addr),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

//============================================================================
// Clock Switching State Machine
//============================================================================
// C counter register format (address 0x05):
//   bit[17]    = odd division enable
//   bit[16]    = bypass enable (0 = normal)
//   bits[15:8] = high count
//   bits[7:0]  = low count
//
// For even divisor N: high = N/2, low = N/2, odd = 0
// For odd divisor N:  high = (N+1)/2, low = N/2, odd = 1
//
// C=20 (even): high=10, low=10, odd=0 → 0x00000A0A
// C=19 (odd):  high=10, low=9,  odd=1 → 0x00020A09
//============================================================================

localparam [31:0] C_48MHZ   = 32'h00000A0A;  // C=20, 48.000000 MHz
localparam [31:0] C_50P5MHZ = 32'h00020A09;  // C=19, 50.526315 MHz

reg [3:0] pll_state = 0;
reg       old_freq_sel;
reg       pll_init_done = 0;

wire freq_sel = status[31];  // 0 = 60Hz (48 MHz), 1 = Original (50.526315 MHz)

reg pll_switching = 0;
reg new_vmode = 0;

always @(posedge CLK_50M) begin
	old_freq_sel <= freq_sel;
	
	if (!pll_waitrequest) begin
		case (pll_state)
			0: begin
				pll_write <= 0;
				if (!pll_init_done || (old_freq_sel != freq_sel)) begin
					pll_state <= 1;
				end
			end
			
			1: begin
				pll_write <= 1;
				pll_addr <= 6'h05;
				pll_data <= freq_sel ? C_50P5MHZ : C_48MHZ;
				pll_state <= 2;
			end
			
			2: begin
				pll_write <= 0;
				pll_state <= 3;
			end
			
			3: begin
				pll_write <= 1;
				pll_addr <= 6'h02;
				pll_data <= 32'h01;
				pll_state <= 4;
			end
			
			4: begin
				pll_write <= 0;
				pll_state <= 5;
			end
			
			5: begin
				if (pll_locked) begin
					pll_init_done <= 1;
					new_vmode <= ~new_vmode;  // Toggle to signal video mode change
					pll_state <= 0;
				end
			end
			
			default: pll_state <= 0;
		endcase
	end
end

//============================================================================
// Input Mapping
//============================================================================
wire m_right   = joystick_0[0];
wire m_left    = joystick_0[1];
wire m_down    = joystick_0[2];
wire m_up      = joystick_0[3];
wire m_shoot   = joystick_0[4];
wire m_shoot2  = joystick_0[5];
wire m_start1p = joystick_0[6];
wire m_start2p = joystick_0[7];
wire m_coin    = joystick_0[8];
wire m_pause   = joystick_0[9];

//============================================================================
// Video Output
//============================================================================
wire hblank, vblank;
wire hs, vs;

wire [3:0] r;
wire [3:0] g;
wire [3:0] b;
wire [11:0] rgb = {rgb_out[11:8], rgb_out[7:4], rgb_out[3:0]};

wire no_rotate = status[2] | direct_video;
wire rotate_ccw = 0;
wire flip = 1'b0;
wire core_flip = status[6];

screen_rotate screen_rotate (.*);

arcade_video #(280, 12) arcade_video
(
	.*,
	.clk_video(clk_vid),
	.ce_pix(core_pix_clk),
	.RGB_in(rgb),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),
	.fx(status[5:3])
);

//============================================================================
// Pause System
//============================================================================
wire pause_cpu;
wire [11:0] rgb_out;

pause #(4, 4, 4, 48) pause
(
	.*,
	.user_button(m_pause),
	.pause_request(hs_pause),
	.options(~status[26:25])
);

//============================================================================
// High Score System
//============================================================================
wire [15:0] hs_address;
wire  [7:0] hs_data_out;
wire  [7:0] hs_data_in;
wire        hs_write;
wire        hs_access_read;
wire        hs_access_write;
wire        hs_pause;
wire        hs_configured;

hiscore #(
	.HS_ADDRESSWIDTH(16),
	.CFG_ADDRESSWIDTH(6),
	.CFG_LENGTHWIDTH(2)
) hi (
	.*,
	.clk(clk_sys),
	.paused(pause_cpu),
	.reset(reset),
	.autosave(status[28]),
	.ram_address(hs_address),
	.data_from_ram(hs_data_out),
	.data_to_ram(hs_data_in),
	.data_from_hps(ioctl_dout),
	.data_to_hps(ioctl_din),
	.ram_write(hs_write),
	.ram_intent_read(hs_access_read),
	.ram_intent_write(hs_access_write),
	.pause_cpu(hs_pause),
	.configured(hs_configured)
);

//============================================================================
// Game Core
//============================================================================
wire rom_download = ioctl_download && (ioctl_index == 0);
wire reset = (RESET | status[0] | buttons[1] | ioctl_download);
assign LED_USER = ioctl_download;
wire core_pix_clk;

slapfight_fpga slapcore
(
	.clkm_48MHZ(clk_sys),
	.pcb(mod_other),
	.flip(core_flip),
	.RED(r),
	.GREEN(g),
	.BLUE(b),
	.core_pix_clk(core_pix_clk),
	.H_SYNC(hs),
	.V_SYNC(vs),
	.H_BLANK(hblank),
	.V_BLANK(vblank),
	.RESET_n(~reset),
	.pause(pause_cpu),
	.CONTROLS(~{m_coin, m_start2p, m_start1p, m_shoot2, m_shoot, m_up, m_down, m_left, m_right}),
	.DIP1(sw[1]),
	.DIP2(sw[2]),
	.dn_addr(ioctl_addr),
	.dn_data(ioctl_dout),
	.dn_wr(ioctl_wr && rom_download),
	.audio_l(AUDIO_L),
	.audio_r(AUDIO_R),
	.hs_address(hs_address),
	.hs_data_out(hs_data_out),
	.hs_data_in(hs_data_in),
	.hs_write(hs_write)
);

endmodule