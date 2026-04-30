/**
 *
 * Name:
 *   bp_uce_prefetcher.sv
 *
 * Description:
 *   This is the UCE side L2 prefetch request generator
 *
 */

`include "bp_common_defines.svh"
`include "bp_me_defines.svh"

module bp_uce_prefetcher
  import bp_common_pkg::*;
  import bp_me_pkg::*;
  #(parameter bp_params_e bp_params_p = e_bp_default_cfg
    , parameter addr_width_p = "inv"
    , parameter block_offset_width_p = "inv"
    , parameter miss_count = "inv"
    )
   (input clk_i
     , input reset_i

     , input req_v_i
     , input miss_i
     , input [addr_width_p-1:0] miss_addr_i

     , output logic prefetch_v_o
     , output logic [addr_width_p-1:0] prefetch_addr_o
     , input prefetch_yumi_i
    );

    logic prefetch_v_r;
    logic [1:0] count_r;
    logic [addr_width_p-1:0] prefetch_addr_r;

    assign prefetch_addr_o = prefetch_addr_r;
    assign prefetch_v_o = prefetch_v_r;

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            prefetch_v_r <= 1'b0;
            prefetch_addr_r <= '0;
            count_r <= '0;
        end
        else begin
            `ifndef SYNTHESIS
                if (miss_i | prefetch_yumi_i | prefetch_v_r)
                $display("[PREFETCHER] time=%0t miss_v=%0b miss_addr=%h v_r=%0b addr_r=%h yumi=%0b count=%0d",
                        $time, miss_i, miss_addr_i, prefetch_v_r, prefetch_addr_r,
                          prefetch_yumi_i, count_r);
            `endif

            if (prefetch_yumi_i) begin
                `ifndef SYNTHESIS
                $display("[PREFETCHER-YUMI] time=%0t clearing addr=%h", $time, prefetch_addr_r);
                `endif
                prefetch_v_r <= 1'b0;
                count_r <= 1'b0;
            end
            if (req_v_i) begin
                if (miss_i) begin
                    if (miss_count == 1) begin
                        prefetch_addr_r <= miss_addr_i + (addr_width_p'(1) << block_offset_width_p);
                        prefetch_v_r <= 1'b1;
                    end else if (miss_addr_i == prefetch_addr_r) begin
                            if (count_r == miss_count) begin
                                prefetch_addr_r <= miss_addr_i + (addr_width_p'(2) << block_offset_width_p);
                                `ifndef SYNTHESIS
                                    $display("[PREFETCHER-SET-V] time=%0t addr=%h", $time, prefetch_addr_r);
                                `endif
                                prefetch_v_r <= 1'b1;
                            end
                            else begin
                                `ifndef SYNTHESIS
                                    if (miss_i | prefetch_yumi_i | prefetch_v_r)
                                    $display("[ADDING] time=%0t miss_v=%0b miss_addr=%h v_r=%0b addr_r=%h yumi=%0b count=%0d",
                                            $time, miss_i, miss_addr_i, prefetch_v_r, prefetch_addr_r,
                                            prefetch_yumi_i, count_r);
                                `endif
                                prefetch_addr_r <= miss_addr_i + (addr_width_p'(1) << block_offset_width_p);
                                count_r <= count_r + 2'd1;
                            end
                    end else begin
                        prefetch_addr_r <= miss_addr_i + (addr_width_p'(1) << block_offset_width_p);
                        prefetch_v_r <= 1'b0;
                        count_r <= 2'd1;
                    end
                end
            end    
        end
    end
endmodule

