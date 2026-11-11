def I(op,rd,f3,rs1,imm): return ((imm&0xfff)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op
def S(f3,rs1,rs2,imm): imm&=0xfff; return ((imm>>5)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((imm&31)<<7)|0x23
def J(rd,imm): imm&=0x1fffff; return (((imm>>20)&1)<<31)|(((imm>>1)&0x3ff)<<21)|(((imm>>11)&1)<<20)|(((imm>>12)&0xff)<<12)|(rd<<7)|0x6f
def U(op,rd,imm): return (imm<<12)|(rd<<7)|op
addi=lambda rd,rs,i: I(0x13,rd,0,rs,i)
lw=lambda rd,rs,i: I(0x03,rd,2,rs,i)
lbu=lambda rd,rs,i: I(0x03,rd,4,rs,i)
sw=lambda rs2,rs1,i: S(2,rs1,rs2,i)
sb=lambda rs2,rs1,i: S(0,rs1,rs2,i)
prog=[
 addi(5,0,1),          #00
 addi(6,0,2),          #04
 J(1,16),              #08 JAL x1,+16 -> 0x18
 addi(10,0,0x11),      #0C
 addi(11,0,0x22),      #10 (buggy JAL lands here)
 addi(12,0,0x33),      #14
 addi(13,0,0x44),      #18 correct target
 U(0x17,14,0x8),       #1C AUIPC x14,0x8 -> 0x801C
 addi(20,0,0x100),     #20
 addi(21,0,0xAA),      #24
 addi(24,0,0x80),      #28
 addi(24,24,0x40),     #2C
 addi(24,24,0x40),     #30 x24=0x100
 lw(26,24,0),          #34 should read old 0x55
 sw(21,20,0),          #38 younger store 0xAA
 addi(28,0,0x200),     #3C
 addi(27,0,0x1FF),     #40
 sb(27,28,0),          #44 mem[0x200] byte0 = 0xFF
 lw(29,28,0),          #48 expect 0x112233FF
 addi(30,0,0x7F0),     #4C  
 lbu(31,28,1),         #50 expect 0x33 
]
with open("prog.hex","w") as f:
  for p in prog: f.write("%08x\n"%p)
