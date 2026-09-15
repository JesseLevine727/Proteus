module uart_tx (
    data,
    baud_div,
    reset,
    clock,
    start,
    tx,
    busy,
    done_
);

    input [7:0] data;
    input [15:0] baud_div;
    input reset;
    input clock;
    input start;
    output tx;
    output busy;
    output done_;

    wire _38;
    wire _34;
    wire _35;
    wire _26;
    wire _36;
    wire _1;
    reg _39;
    wire _48;
    wire _45;
    wire _42;
    wire _46;
    wire _41;
    wire _49;
    wire _3;
    reg _52;
    wire [7:0] _57;
    wire [7:0] _6;
    wire [7:0] _64;
    wire [6:0] _60;
    wire [7:0] _61;
    wire [7:0] _62;
    wire _55;
    wire [7:0] _63;
    wire _53;
    wire [7:0] _65;
    wire [7:0] _7;
    reg [7:0] _58;
    wire _123;
    wire _119;
    wire _122;
    wire _118;
    wire _124;
    wire [1:0] _22;
    wire [1:0] _115;
    wire [1:0] _113;
    wire [2:0] _71;
    wire [2:0] _69;
    wire [2:0] _79;
    wire [2:0] _73;
    wire [2:0] _74;
    wire [2:0] _75;
    wire [2:0] _76;
    wire _67;
    wire [2:0] _77;
    wire _66;
    wire [2:0] _80;
    wire [2:0] _8;
    reg [2:0] _70;
    wire _72;
    wire [1:0] _110;
    wire [1:0] _111;
    wire [15:0] _31;
    wire [15:0] _10;
    wire [15:0] _32;
    wire vdd;
    wire [15:0] _29;
    wire _12;
    wire _14;
    wire _16;
    wire [15:0] _102;
    wire [15:0] _97;
    wire [15:0] _99;
    wire [15:0] _92;
    wire [15:0] _94;
    wire [15:0] _87;
    wire [15:0] _89;
    wire _85;
    wire [15:0] _90;
    wire _84;
    wire [15:0] _95;
    wire _83;
    wire [15:0] _100;
    wire _81;
    wire [15:0] _103;
    wire [15:0] _17;
    reg [15:0] _30;
    wire _33;
    wire [1:0] _108;
    wire [1:0] _25;
    wire _107;
    wire [1:0] _109;
    wire [1:0] _54;
    wire _106;
    wire [1:0] _112;
    wire [1:0] _82;
    wire _105;
    wire [1:0] _114;
    wire _104;
    wire [1:0] _116;
    wire [1:0] _18;
    reg [1:0] _24;
    wire _117;
    wire _126;
    wire _19;
    reg _129;
    assign _38 = 1'b0;
    assign _34 = 1'b1;
    assign _35 = _33 ? _34 : _38;
    assign _26 = _24 == _25;
    assign _36 = _26 ? _35 : _38;
    assign _1 = _36;
    always @(posedge _14) begin
        if (_12)
            _39 <= _38;
        else
            _39 <= _1;
    end
    assign _48 = _16 ? _34 : _38;
    assign _45 = _33 ? _38 : _38;
    assign _42 = _24 == _25;
    assign _46 = _42 ? _45 : _38;
    assign _41 = _24 == _22;
    assign _49 = _41 ? _48 : _46;
    assign _3 = _49;
    always @(posedge _14) begin
        if (_12)
            _52 <= _38;
        else
            _52 <= _3;
    end
    assign _57 = 8'b00000000;
    assign _6 = data;
    assign _64 = _16 ? _6 : _58;
    assign _60 = _58[7:1];
    assign _61 = { _38,
                   _60 };
    assign _62 = _33 ? _61 : _58;
    assign _55 = _24 == _54;
    assign _63 = _55 ? _62 : _58;
    assign _53 = _24 == _22;
    assign _65 = _53 ? _64 : _63;
    assign _7 = _65;
    always @(posedge _14) begin
        if (_12)
            _58 <= _57;
        else
            _58 <= _7;
    end
    assign _123 = _58[0:0];
    assign _119 = _24 == _25;
    assign _122 = _119 ? _34 : _34;
    assign _118 = _24 == _54;
    assign _124 = _118 ? _123 : _122;
    assign _22 = 2'b00;
    assign _115 = _16 ? _82 : _24;
    assign _113 = _33 ? _54 : _24;
    assign _71 = 3'b111;
    assign _69 = 3'b000;
    assign _79 = _16 ? _69 : _70;
    assign _73 = 3'b001;
    assign _74 = _70 + _73;
    assign _75 = _72 ? _70 : _74;
    assign _76 = _33 ? _75 : _70;
    assign _67 = _24 == _54;
    assign _77 = _67 ? _76 : _70;
    assign _66 = _24 == _22;
    assign _80 = _66 ? _79 : _77;
    assign _8 = _80;
    always @(posedge _14) begin
        if (_12)
            _70 <= _69;
        else
            _70 <= _8;
    end
    assign _72 = _70 == _71;
    assign _110 = _72 ? _25 : _24;
    assign _111 = _33 ? _110 : _24;
    assign _31 = 16'b0000000000000001;
    assign _10 = baud_div;
    assign _32 = _10 - _31;
    assign vdd = 1'b1;
    assign _29 = 16'b0000000000000000;
    assign _12 = reset;
    assign _14 = clock;
    assign _16 = start;
    assign _102 = _16 ? _29 : _30;
    assign _97 = _30 + _31;
    assign _99 = _33 ? _29 : _97;
    assign _92 = _30 + _31;
    assign _94 = _33 ? _29 : _92;
    assign _87 = _30 + _31;
    assign _89 = _33 ? _29 : _87;
    assign _85 = _24 == _25;
    assign _90 = _85 ? _89 : _30;
    assign _84 = _24 == _54;
    assign _95 = _84 ? _94 : _90;
    assign _83 = _24 == _82;
    assign _100 = _83 ? _99 : _95;
    assign _81 = _24 == _22;
    assign _103 = _81 ? _102 : _100;
    assign _17 = _103;
    always @(posedge _14) begin
        if (_12)
            _30 <= _29;
        else
            _30 <= _17;
    end
    assign _33 = _30 == _32;
    assign _108 = _33 ? _22 : _24;
    assign _25 = 2'b11;
    assign _107 = _24 == _25;
    assign _109 = _107 ? _108 : _24;
    assign _54 = 2'b10;
    assign _106 = _24 == _54;
    assign _112 = _106 ? _111 : _109;
    assign _82 = 2'b01;
    assign _105 = _24 == _82;
    assign _114 = _105 ? _113 : _112;
    assign _104 = _24 == _22;
    assign _116 = _104 ? _115 : _114;
    assign _18 = _116;
    always @(posedge _14) begin
        if (_12)
            _24 <= _22;
        else
            _24 <= _18;
    end
    assign _117 = _24 == _82;
    assign _126 = _117 ? _38 : _124;
    assign _19 = _126;
    always @(posedge _14) begin
        if (_12)
            _129 <= _38;
        else
            _129 <= _19;
    end
    assign tx = _129;
    assign busy = _52;
    assign done_ = _39;

endmodule
