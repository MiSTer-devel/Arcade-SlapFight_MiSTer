derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
create_clock -name {emu:emu|slapfight_fpga:slapcore|pixel_clk} -period 166.000 -waveform { 0.000 83.000 } [get_nets {emu|slapcore|pixel_clk}]