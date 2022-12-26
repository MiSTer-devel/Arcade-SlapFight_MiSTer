module background_layer (
	input master_clk,
	input pixel_clk,
	input [7:0] VPIXSCRL,
	input [8:0] HPIXSCRL,
	input SCREEN_FLIP,
	input BACKGRAM_1,
	input BACKGRAM_2,
	input Z80_WR,
	input Z80_RD,
	input CPU_RAM_SYNC,
	input [15:0] CPU_ADDR,
	input  [7:0] CPU_DIN,
	input [24:0] dn_addr,
	input [7:0] dn_data,
	input ep5_cs_i,
	input ep6_cs_i,
	input ep7_cs_i,
	input ep8_cs_i,
	input dn_wr,
	output [7:0] BG_HI_out,
	output [7:0] BG_LO_out,
	output [7:0] pixel_output,
	output BG_WAIT
);

wire [15:0] BG_RAMD;
reg [7:0] BG_PX_D;

//reg [11:0] tilecnt;
//reg [3:0] pause_cnt;

//always @(posedge VPIXSCRL[7]) pause_cnt <= pause_cnt +1;
//always @(posedge pause_cnt[3]) tilecnt <= tilecnt +1;
	
	wire SH_REG_DIR=!SCREEN_FLIP;
	wire BG_CLK=(SCREEN_FLIP^!HPIXSCRL[2]);
	wire BG_SYNC=!(BG_CLK&(SCREEN_FLIP^!HPIXSCRL[0])&(SCREEN_FLIP^HPIXSCRL[1]));
	wire BG_COLOUR_COPY=BG_SYNC|pixel_clk;
	wire BG_SELECT=BG_SYNC|CPU_RAM_SYNC;
	wire BG_S0=!(BG_SELECT& SCREEN_FLIP);
	wire BG_S1=!(BG_SELECT&!SCREEN_FLIP);
	

dpram_dc #(.widthad_a(11)) BG_U4N //sf
(
	.clock_a(master_clk),
	.address_a({VPIXSCRL[7:3],HPIXSCRL[8:3]}), //
	.data_a(CPU_DIN),
	.wren_a(1'b0),
	.q_a(BG_RAMD[7:0]),
	
	.clock_b(master_clk),
	.address_b(CPU_ADDR[10:0]),
	.data_b(CPU_DIN),
	.wren_b(!BACKGRAM_1 & !Z80_WR),
	.q_b(BG_LO_out)		

);

dpram_dc #(.widthad_a(11)) BG_U4P //sf
(
	.clock_a(master_clk),
	.address_a({VPIXSCRL[7:3],HPIXSCRL[8:3]}), //{VPIXSCRL[7:3],HPIXSCRL[8:3]}
	.data_a(CPU_DIN),
	.wren_a(1'b0),
	.q_a(BG_RAMD[15:8]),

	.clock_b(master_clk),
	.address_b(CPU_ADDR[10:0]),
	.data_b(CPU_DIN),
	.wren_b(!BACKGRAM_2 & !Z80_WR),
	.q_b(BG_HI_out)
);

wire [7:0] U6P_BG_A77_05_out;
wire [7:0] U6N_BG_A77_06_out;
wire [7:0] U6M_BG_A77_07_out;
wire [7:0] U6K_BG_A77_08_out; //eprom data output

/* - COMMENTED OUT TO SAVE MEMORY, WILL NEED TO SWITCH TO A DIFFERENT MODEL*/
/*
bg_gfx_05 U6P_BG_A77_05
(
	.clk(master_clk),
	.addr({BG_RAMD[11:0],VPIXSCRL[2:0]}),
	.data(U6P_BG_A77_05_out)
);

bg_gfx_06 U6N_BG_A77_06
(
	.clk(master_clk),
	.addr({BG_RAMD[11:0],VPIXSCRL[2:0]}),
	.data(U6N_BG_A77_06_out)
);

bg_gfx_07 U6M_BG_A77_07
(
	.clk(master_clk),
	.addr({BG_RAMD[11:0],VPIXSCRL[2:0]}),
	.data(U6M_BG_A77_07_out)
);

bg_gfx_08 U6K_BG_A77_08
(
	.clk(master_clk),
	.addr({BG_RAMD[11:0],VPIXSCRL[2:0]}),
	.data(U6K_BG_A77_08_out)
);

*/

eprom_5 U6P_BG_A77_05
(
	.ADDR({BG_RAMD[11:0],VPIXSCRL[2:0]}),//BG_RAMD[11:0]
	.CLK(master_clk),//
	.DATA(U6P_BG_A77_05_out),//
	.ADDR_DL(dn_addr),
	.CLK_DL(!master_clk),//
	.DATA_IN(dn_data),
	.CS_DL(ep5_cs_i),
	.WR(dn_wr)
);


eprom_6 U6N_BG_A77_06
(
	.ADDR({BG_RAMD[11:0],VPIXSCRL[2:0]}),//
	.CLK(master_clk),//
	.DATA(U6N_BG_A77_06_out),//
	.ADDR_DL(dn_addr),
	.CLK_DL(!master_clk),//
	.DATA_IN(dn_data),
	.CS_DL(ep6_cs_i),
	.WR(dn_wr)
);

eprom_7 U6M_BG_A77_07
(
	.ADDR({BG_RAMD[11:0],VPIXSCRL[2:0]}),//
	.CLK(master_clk),//
	.DATA(U6M_BG_A77_07_out),//
	.ADDR_DL(dn_addr),
	.CLK_DL(!master_clk),//
	.DATA_IN(dn_data),
	.CS_DL(ep7_cs_i),
	.WR(dn_wr)
);

eprom_8 U6K_BG_A77_08
(
	.ADDR({BG_RAMD[11:0],VPIXSCRL[2:0]}),//
	.CLK(master_clk),//
	.DATA(U6K_BG_A77_08_out),//
	.ADDR_DL(dn_addr),
	.CLK_DL(!master_clk),//
	.DATA_IN(dn_data),
	.CS_DL(ep8_cs_i),
	.WR(dn_wr)
);

/* */
wire U7PN_QA,U7PN_QH,U7LM_QA,U7LM_QH,U3ML_QA,U3ML_QH,U7KJ_QA,U7KJ_QH;

	ls299 U7PN (
		.clk(pixel_clk),
		.pin(U6P_BG_A77_05_out),
		.S0(BG_S0),
		.S1(BG_S1),
		.QA(U7PN_QA),
		.QH(U7PN_QH)
	);

	ls299 U7LM (
		.clk(pixel_clk),
		.pin(U6N_BG_A77_06_out),
		.S0(BG_S0),
		.S1(BG_S1),
		.QA(U7LM_QA),
		.QH(U7LM_QH)
	);

	ls299 U3ML (
		.clk(pixel_clk),
		.pin(U6M_BG_A77_07_out),
		.S0(BG_S0),
		.S1(BG_S1),
		.QA(U3ML_QA),
		.QH(U3ML_QH)
	);

	ls299 U7KJ (
		.clk(pixel_clk),
		.pin(U6K_BG_A77_08_out),
		.S0(BG_S0),
		.S1(BG_S1),
		.QA(U7KJ_QA),
		.QH(U7KJ_QH)
	);
	
	always @(*) begin 
		BG_PX_D[3:0] <= (SH_REG_DIR) ? {U7KJ_QH,U3ML_QH,U7LM_QH,U7PN_QH} : {U7KJ_QA,U3ML_QA,U7LM_QA,U7PN_QA} ;
	end
	
	always @(posedge BG_COLOUR_COPY) BG_PX_D[7:4]<=BG_RAMD[15:12];//pause_cnt;//BG_RAMD[15:12];

	assign pixel_output=BG_PX_D;

	//background wait states
	wire BG_CHIP_SEL=BACKGRAM_1&BACKGRAM_2;
	reg [7:0] count_wait;
	wire nBG_CLK=!BG_CLK; 
	reg BG_CS_OLD;
	reg BG_WAIT_out;
	always @(posedge nBG_CLK) begin
		count_wait= (!BG_CHIP_SEL&BG_CS_OLD) ? 8'b11000000 : count_wait<<1;
		BG_WAIT_out=count_wait[7];
		BG_CS_OLD=BG_CHIP_SEL;
	end

 	assign BG_WAIT=BG_CHIP_SEL|BG_WAIT_out;

endmodule
