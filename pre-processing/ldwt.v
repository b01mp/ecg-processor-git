module ldwt_db4_csd (
    input  clk,
    input  rst,
    input  signed [15:0] y_even,       // y[2n]
    input  signed [15:0] y_odd,        // y[2n+1]
    input  signed [15:0] y_even_next,  // y[2n+2]
    output reg signed [15:0] a_out,    // approximation coeff
    output reg signed [15:0] d_out     // detail coeff
);

    // Internal registers
    reg signed [15:0] dn1, an1, dn2;
    reg signed [31:0] temp1, temp2, temp3;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dn1  <= 0;
            an1  <= 0;
            dn2  <= 0;
            a_out <= 0;
            d_out <= 0;
        end else begin
            // --- Step 1: dn1 = y_odd - ((√3 - 1)/4)*(y_even + y_even_next)
            temp1 = y_even + y_even_next;
            // Approximate (√3 - 1)/4 with shifts: (x>>2 + x>>3 + x>>5)
            temp2 = (temp1 >>> 2) + (temp1 >>> 3) + (temp1 >>> 5);
            dn1  <= y_odd - temp2[15:0];

            // --- Step 2: an1 = y_even + (√3/4)*(dn1 + dn1_prev)
            // For simplicity assume dn1_prev = dn1 (streaming delay = 1)
            temp3 = (dn1 >>> 2) + (dn1 >>> 3);   // (√3/4) ≈ x>>2 + x>>3
            an1  <= y_even + temp3[15:0];

            // --- Step 3: dn2 = dn1 + ((√3 + 1)/4)*an1
            temp1 = (an1 >>> 1) + (an1 >>> 4);   // (√3 + 1)/4 ≈ x>>1 + x>>4
            dn2  <= dn1 + temp1[15:0];

            // --- Step 4: scaling by 1/√2 (x>>1 + x>>4)
            temp2 = (an1 >>> 1) + (an1 >>> 4);
            temp3 = (dn2 >>> 1) + (dn2 >>> 4);

            a_out <= temp2[15:0];
            d_out <= temp3[15:0];
        end
    end
endmodule
