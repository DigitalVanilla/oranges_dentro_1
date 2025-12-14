        include "includes/hw.i"
        include "includes/macros.i"
        include "includes/startup.i"
        include "includes/sin.i"
        include "pt_player_3b.s"        
********************************************************************************

PERSP_SHIFT = 8
POINT_COUNT = 14
FACE_COUNT = 24

H_PAD = 14

BLITTER_BITPLANES = 3
FP_BITS = 3
SubPixelBlitterEdgeLine_Mask = (1<<FP_BITS)-1

LINE_MINTERM = $4a ;xor

SIN_LEN = 1024

FP2I14FP macro
        lsl.l   #2+FP_BITS,\1
        swap    \1
        endm

FP2I14  macro
        lsl.l   #2,\1
        swap    \1
        endm

FPMULS14 macro
        muls    \1,\2
        FP2I14  \2
        endm

; ------------- Display setup:

BPLS = 5                ; Bitplane count
DIW_W = 320             ; Display window width
DIW_H = 256             ; Display window height
INTERLEAVED = 0         ; Interleaved bitplanes?
SCROLL = 0              ; Enable playfield scroll (add additional word of data fetch)
DPF = 0                 ; Enable dual playfield
HAM = 0                 ; Enable HAM
HIRES = 0               ; Enable hi-res mode
LACE = 0                ; Enable interlace
PF1P = 0                ; Playfield 1 priority code (with respect to sprites)
PF2P = 0                ; Playfield 2 priority code (with respect to sprites)
PF2PRI = 0              ; Playfield 2 (even planes) has priority over (appears in front of) playfield 1 (odd planes).

SCREEN_W = DIW_W        ; Screen buffer width
SCREEN_H = DIW_H        ; Screen buffer height

; Initial DMA/Interrupt bits:
DMASET = DMAF_SETCLR!DMAF_MASTER!DMAF_RASTER!DMAF_COPPER!DMAF_BLITTER!DMAF_SPRITE
INTSET = INTF_SETCLR!INTF_INTEN!INTF_VERTB

COLORS = 1<<BPLS        ; Number of palette colours
SCREEN_BW = SCREEN_W/16*2 ; byte-width of 1 bitplane line

        ifne    INTERLEAVED
SCREEN_MOD = SCREEN_BW*(BPLS-1) ; modulo (interleaved)
SCREEN_BPL = SCREEN_BW  ; bitplane offset (interleaved)
        else
SCREEN_MOD = 0          ; modulo (non-interleaved)
SCREEN_BPL = SCREEN_BW*SCREEN_H ; bitplane offset (non-interleaved)
        endc

SCREEN_SIZE = SCREEN_BW*SCREEN_H*BPLS ; byte size of screen buffer
DIW_BW = DIW_W/16*2     ; Display window bit width
DIW_MOD = SCREEN_BW-DIW_BW+SCREEN_MOD-SCROLL*2
DIW_SIZE = DIW_BW*DIW_H*BPLS ; Display window byte size
DIW_LW = DIW_W/(HIRES+1) ; low res width

; Display windows bounds for centered PAL display:
DIW_XSTRT = $81+(320-DIW_LW)/2
DIW_YSTRT = $2c+(256-DIW_H)/2
DIW_XSTOP = DIW_XSTRT+DIW_LW
DIW_YSTOP = DIW_YSTRT+DIW_H

; Text related
INITIAL_PAUSE_TEXT = 70
BETWEEN_LINES_PAUSE = 10
BETWEEN_PAGES_PAUSE = 200
TOTAL_PAGES = 6
FONT_HEIGHT = 8
TOTAL_LINES = DIW_H/FONT_HEIGHT

; Logo sprite
INITIAL_PAUSE_SPRITE = 50
END_VPOS = $30

; HUE Color Shift
BETWEEN_HUE_COLOR_SHIFT_PAUSE = 6

; ------------- Init

Entrypoint:
        ; init tracker player
        bsr.w   pt_InitMusic

        ; render pattern motif in both draw and view screens
        ; because it does do not need to be render at every frame
        move.l  #pattern_0_start,pattern_current_address_start
        move.l  #pattern_0_end,pattern_current_address_end
        bsr     make_grid_draw_screen
        bsr     make_grid_view_screen

        ; set the initial text pointers        
        bsr     set_message

        bsr     init_logo_sprite

        move.l  #Interrupt,$6c(a4)
        move.w  #INTSET,intena(a6)
        bsr     WaitEOF
        move.l  #CopperStart,cop1lc(a6)
        move.w  #DMASET,dmacon(a6)

; ------------- Main Loop

.mainLoop:
        move.w  #DMAF_BLITHOG,dmacon(a6)
        
        lea     DrawScreen(pc),a0

        ; do the glenz magic!
        bsr     Clear
        bsr     Update
        bsr     Transform
        bsr     Draw
        
        move.w  #DMAF_BLITHOG!DMAF_SETCLR,dmacon(a6)
        BLIT_WAIT
        
        ; ; display the render results
        bsr     SwapBuffers
        
        bsr     WaitEOF

        ; check left mouse button pressed (if not, let's keep looping)
        btst    #CIAB_GAMEPORT0,ciaa
        bne     .mainLoop

.exit:
        ; stop the music
        bsr.w   pt_StopMusic
        rts

; ------------- Vsynch

Interrupt:
        movem.l d0-a6,-(sp)
        lea     custom,a6
        btst    #INTB_VERTB,intreqr+1(a6)
        beq.s   .notvb

        ; Vertical blank interrupt
        lea     Frame(pc),a0
        addq.w  #1,(a0)

        ; play the mod tune
        bsr.w	pt_PlayMusic
        
        ; text render
        bsr.w   main_text_render
        bsr.w   move_logo_sprite
        
        ; hue color shift
        bsr.w   main_hue_shift
        
.continue_vbs:
        moveq   #INTF_VERTB,d0
        move.w  d0,intreq(a6)
        move.w  d0,intreq(a6)
.notvb: movem.l (sp)+,d0-a6
        rte

; ------------- Background Pattern

pattern_current_address_start:  
        dc.l    0
pattern_current_address_end:  
        dc.l    0

make_grid_draw_screen:
        movem.l d0-a6,-(sp)
        move.l  DrawScreen(pc),a0
        add.w   #40*29,a0
        move.l  pattern_current_address_start,a3
        move.l  pattern_current_address_end,a4

        move.w  #(64*3),d0
.loopLines:

        move.l  (a3)+,d3
        move.l  (a3)+,d4
        
        ; draw the grid pattern into the 1st bitplane
        REPT    SCREEN_BW/8
        move.l  d3,(a0)+
        move.l  d4,(a0)+
        endr

        cmp.l   a3,a4
        bne     .continue_loop   

.reset_pattern_pointer:
        move.l  (pattern_current_address_start),a3

.continue_loop:
        dbra    d0,.loopLines
        movem.l (sp)+,d0-a6
        
        rts

make_grid_view_screen:
        movem.l d0-a6,-(sp)
        move.l  ViewScreen,a0
        add.w   #40*29,a0
        move.l  (pattern_current_address_start),a3
        move.l  (pattern_current_address_end),a4

        move.w  #(64*3),d0
.loopLines:

        move.l  (a3)+,d3
        move.l  (a3)+,d4
        
        ; draw the grid pattern into the 1st bitplane
        REPT    SCREEN_BW/8
        move.l  d3,(a0)+
        move.l  d4,(a0)+
        endr

        cmp.l   a3,a4
        bne     .continue_loop   

.reset_pattern_pointer:
        move.l  (pattern_current_address_start),a3

.continue_loop:
        dbra    d0,.loopLines
        movem.l (sp)+,d0-a6
        
        rts

pattern_0_start:
        dc.l	$38e08880
        dc.l    $0088838e
	dc.l	$20208800
        dc.l    $00088202
	dc.l	$e023f800
        dc.l    $000fe203
	dc.l	$80220808
        dc.l    $88082200
	dc.l	$822208ff
        dc.l    $ff882220
	dc.l	$03fe0020
        dc.l    $82003fe0
	dc.l	$0e038020
        dc.l    $8200e038
	dc.l	$04010020
        dc.l    $82004010
	dc.l	$840108f8
        dc.l    $8f884010
	dc.l	$84210f88
        dc.l    $88f84210
	dc.l	$fc701888
        dc.l    $888c071f
	dc.l	$04201000
        dc.l    $00040210
	dc.l	$04001000
        dc.l    $00040010
	dc.l	$04011000
        dc.l    $00044010
	dc.l	$3e03fc46
        dc.l    $311fe03e
	dc.l	$23c62044
        dc.l    $110231e2
	dc.l	$e202207c
        dc.l    $1f022023
	dc.l	$20022044
        dc.l    $11022002
	dc.l	$2003f1c7
        dc.l    $f1c7e002
	dc.l	$203e2100
        dc.l    $80423e02
	dc.l	$f8e20100
        dc.l    $0040238f
	dc.l	$00420100
        dc.l    $00402100
	dc.l	$00400388
        dc.l    $08e00100
	dc.l	$00403e08
        dc.l    $883e0100
	dc.l	$88e0220f
        dc.l    $f8220388
	dc.l	$0883e008
        dc.l    $8803e088
	dc.l	$0f808038
        dc.l    $0e0080f8
	dc.l	$08808020
        dc.l    $02008088
	dc.l	$18e083e0
        dc.l    $03e0838c
	dc.l	$0803e080
        dc.l    $8083e008
	dc.l	$08022083
        dc.l    $e0822008
	dc.l	$08002082
        dc.l    $20820008
	dc.l	$1fe031c6
        dc.l    $31c603fc
	dc.l	$08002082
        dc.l    $20820008
	dc.l	$08022083
        dc.l    $e0822008
	dc.l	$0803e080
        dc.l    $8083e008
	dc.l	$18e083e0
        dc.l    $03e0838c
	dc.l	$08808020
        dc.l    $02008088
	dc.l	$0f808038
        dc.l    $0e0080f8
	dc.l	$0883e008
        dc.l    $8803e088
	dc.l	$88e0220f
        dc.l    $f8220388
	dc.l	$00403e08
        dc.l    $883e0100
	dc.l	$00400388
        dc.l    $08e00100
	dc.l	$00420100
        dc.l    $00402100
	dc.l	$f8e20100
        dc.l    $0040238f
	dc.l	$203e2100
        dc.l    $80423e02
	dc.l	$2003f1c7
        dc.l    $f1c7e002
	dc.l	$20022044
        dc.l    $11022002
	dc.l	$e202207c
        dc.l    $1f022023
	dc.l	$23c62044
        dc.l    $110231e2
	dc.l	$3e03fc46
        dc.l    $311fe03e
	dc.l	$04011000
        dc.l    $00044010
	dc.l	$04001000
        dc.l    $00040010
	dc.l	$04201000
        dc.l    $00040210
	dc.l	$fc701888
        dc.l    $888c071f
	dc.l	$84210f88
        dc.l    $88f84210
	dc.l	$840108f8
        dc.l    $8f884010
	dc.l	$04010020
        dc.l    $82004010
	dc.l	$0e038020
        dc.l    $8200e038
	dc.l	$03fe0020
        dc.l    $82003fe0
	dc.l	$822208ff
        dc.l    $ff882220
	dc.l	$80220808
        dc.l    $88082200
	dc.l	$e023f800
        dc.l    $000fe203
	dc.l	$20208800
        dc.l    $00088202
pattern_0_end:
        dc.l    0,0,0,0
   
; ------------- Message

page_draw_starting_bitplane_text: 
        dc.l    0

page_view_starting_bitplane_text:
        dc.l    0

page_address_pointer:
        dc.l    0

line_index_counter:
        dc.w    0

page_index_counter:
        dc.w    0

initial_pause_text_counter:
        dc.w    0

pause_between_lines_counter:
        dc.w    0

pause_between_pages_counter:
        dc.w    0

main_text_render:
        cmp.w   #INITIAL_PAUSE_TEXT,initial_pause_text_counter
        bge     .continue
        ble     .initial_delay

.continue
        ; we've reach the last line so we skip the render
        ; and reset pointers and counters for the next page
        cmp.w   #TOTAL_LINES,line_index_counter
        bge     next_page

.line_between_wait_counter:
        addq    #1,pause_between_lines_counter
        cmp.w   #BETWEEN_LINES_PAUSE,pause_between_lines_counter
        bne.s   .skip

        ; reset the counter of wait between each line
        clr     pause_between_lines_counter

        ; full block of text render
        ; render the text in both draw and view screens
        ; because it does do not need to be render at every frame
        bsr     print_text_draw_screen
        bsr     print_text_view_screen
        ; move to the next line	in the text        
	add.l	#40,page_address_pointer
        ; move to the next line index
        addq.w  #1,line_index_counter
        bra.s   .skip

.initial_delay:
        addq.w  #1,initial_pause_text_counter

.skip:
        rts
        
print_text_draw_screen:
        movem.l d0-a5,-(sp)
        move.l  (page_draw_starting_bitplane_text),a0
        move.l  (page_address_pointer),a1

        move.l  a0,a3
        ; draw the texts into the 5th bitplane
        add.l   #(SCREEN_BW*SCREEN_H*(BPLS-1)),a3
        
        ; 23 lines available in total
        ; 40 columns with 8px wide font
        REPT    40
        clr     d2		
        move.b  (a1)+,d2	
        sub.b   #$20,d2			
        mulu.w  #8,d2		
        move.l  d2,a2           
        add.l   #Font,a2
        
        ; we need to cycle 8 times because the height of the font is 8 pixel, and we start with 0 always
        REPT    7	
        move.b  (a2)+,40*REPTN(a3)
        ENDR
        addq.w  #1,a3
        ENDR
        
        ; move to the next line position in the screen
        add.l	#40*FONT_HEIGHT,page_draw_starting_bitplane_text

        movem.l (sp)+,d0-a5
        rts

print_text_view_screen:
        movem.l d0-a5,-(sp)
        move.l  page_view_starting_bitplane_text,a0
        move.l  page_address_pointer,a1

        move.l  a0,a3
        ; draw the text into the 5th bitplane
        add.l   #(SCREEN_BW*SCREEN_H*(BPLS-1)),a3

        ; 23 lines available in total
        ; 40 columns with 8px wide font
        REPT    40
        clr     d2		
        move.b  (a1)+,d2	
        sub.b   #$20,d2			
        mulu.w  #8,d2		
        move.l  d2,a2           
        add.l   #Font,a2
        
        ; we need to cycle 8 times because the height of the font is 8 pixel, and we start with 0 always
        REPT    7	
        move.b  (a2)+,40*REPTN(a3)
        ENDR
        addq.w  #1,a3
        ENDR
        
        ; move to the next line position in the screen
        add.l	#40*FONT_HEIGHT,page_view_starting_bitplane_text

        movem.l (sp)+,d0-a5
        rts

set_message:
        clr     line_index_counter
        clr     pause_between_pages_counter
        
        move.l  DrawScreen(pc),page_draw_starting_bitplane_text
        move.l  ViewScreen(pc),page_view_starting_bitplane_text

        cmp.w	#0,page_index_counter  
        beq.w	set_message_0
        
        cmp.w	#1,page_index_counter        
        beq.w	set_message_1
        
        cmp.w	#2,page_index_counter 
        beq.w	set_message_2

        cmp.w	#3,page_index_counter 
        beq.w	set_message_3
        
        cmp.w	#4,page_index_counter 
        beq.w	set_message_4

        cmp.w	#5,page_index_counter 
        beq.w	set_message_5
        
        rts
    
set_message_0:
        move.l	#message_0,page_address_pointer
        rts

set_message_1:
        move.l	#message_1,page_address_pointer
        rts
        
set_message_2:
        move.l  #message_2,page_address_pointer             
        rts

set_message_3:
        move.l  #message_3,page_address_pointer             
        rts

set_message_4:
        move.l  #message_4,page_address_pointer             
        rts

set_message_5:
        move.l  #message_5,page_address_pointer             
        rts

next_page:
        ; counter to wait N vbs between each pages
        ; after the last line was render
        ; before moving to the next page
        addq.w  #1,pause_between_pages_counter
        cmp.w   #BETWEEN_PAGES_PAUSE,pause_between_pages_counter
        bne     .continue

        ; some good values reset
        clr     pause_between_pages_counter
        clr     line_index_counter
        addq.w  #1,page_index_counter
        ; over last page?
        cmp.w   #TOTAL_PAGES,page_index_counter
        bne     .next

.zero:
        ; reaching the last page we need to restart from the first
        clr     page_index_counter

.next:
        bsr.w   set_message
        
.continue:
        rts

message_0:
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                        HOWDY FOLKS AND '
        dc.b    '                   WELCOME TO THIS FINE '
        dc.b    '                  PRODUCTION BY ORANGES '
        dc.b    '                                 CALLED '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '               ************************ '
        dc.b    '               *                      * '
        dc.b    '               *  WE LOVE CRACKTROS!  * ' 
        dc.b    '               *                      * '
        dc.b    '               ************************ '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        even

message_1:
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                   Proudly presenting:  '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                 >> Mystery Game +11 << '
        dc.b    '                                        '
        dc.b    '                            by          '
        dc.b    '                                        '
        dc.b    '                  Mystery Company,2025  '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                The game everyone knows '
        dc.b    '                       but nobody talks '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        even

message_2:
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '               Successfully implemented '
        dc.b    '                   Glenz (thanks Giga!) '
        dc.b    '                    for the first time, '
        dc.b    '         got some shenanigans as usual, '
        dc.b    '              but promptly solved them! '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                 Im not sure if this is '
        dc.b    '              ready for big mega compos '
        dc.b    '                        but I like more '
        dc.b    '                    the "snack feeling" '
        dc.b    '                of fast mini cracktros. '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        even

message_3:
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                         Code this time '
        dc.b    '                       is much cleaner, '
        dc.b    '                as usual not optimized, '
        dc.b    '                  but hey, it works! :) '
        dc.b    '                                        '
        dc.b    '                Enjoy the looping track '
        dc.b    '                    and now time for... '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                Credits '
        dc.b    '                                        '
        dc.b    '                       Code/GFX by Lynx '
        dc.b    '                       Music by Kast601 '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        even

message_4:
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                            Lynx greetz '
        dc.b    '                                        ' 
        dc.b    '                                        '
        dc.b    '                          Xad/Nightfall '
        dc.b    '                       Gigabates/DESiRE '
        dc.b    '                             Proton/FIG '
        dc.b    '                            Spreadpoint '
        dc.b    '                               Pellicus '
        dc.b    '                                 Sander '
        dc.b    '                               DannyHey '
        dc.b    '                                Prowler '
        dc.b    '                                Virgill '
        dc.b    '                                Ok3anos '
        dc.b    '                               Elkmoose ' 
        dc.b    '                                 Morten ' 
        dc.b    '                                   Lexo ' 
        dc.b    '                               Buldozer '     
        dc.b    '                                  Cebit '     
        dc.b    '                           Roby, Andrew '     
        dc.b    '                    and all the rest... ' 
        dc.b    '                                        ' 
        dc.b    '                                        ' 
        dc.b    '                                        ' 
        dc.b    '                                        ' 
        dc.b    '                                        ' 
        dc.b    '                                        '
        
        even

message_5:
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                         Kast601 greetz '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                          Jester/Sanity '
        dc.b    '                                Scoopex '
        dc.b    '                              lfo/VyRaL '
        dc.b    '                      Maktone/Fairlight '
        dc.b    '                   DslashV/Hokuto Force '
        dc.b    '                             Resistance '
        dc.b    '                HoMiCiDe/Synergy Design '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        dc.b    '                                        '
        even

; ------------- 3D Math Glenz

Update:
        lea     Vars(pc),a5
        move.w  Frame(pc),d0
        move.w  #(SIN_LEN-1)*2,d4

        ; Z angle = frame * 4
        move.w  d0,d1
        lsl.w   #2,d1
        and.w   d4,d1
        ; Y angle = frame * 8
        move.w  d0,d2
        lsl.w   #3,d2
        and.w   d4,d2
        ; X angle = frame * 2
        move.w  d0,d3
        lsl.w   #1,d3
        and.w   d4,d3

        movem.w d1-d3,Rot-Vars(a5)

        move.w  Frame(pc),d0
        lsl.w #3,d0
        lea Sin(pc),a0
        and.w  #(SIN_LEN-1),d0
        move.w (a0,d0),d0
        asr.w #6,d0
        add.w #180,d0
        move.w d0,Dist

        rts

Transform:
        ; First, build the rotation matrix from the three angles
        bsr     BuildRotationMatrix

        ; Now transform all points using the matrix
        lea     Points,a0
        lea     PointsTransformed,a1
        move.w  #POINT_COUNT-1,d7
.l
        movem.w (a0)+,d4-d6

        ; Apply rotation matrix to a point
        ;-------------------------------------------------------------------------------
        lea     Matrix(pc),a2

        ; Calculate new x = m00*x + m01*y + m02*z
        move.w  (a2)+,d0
        muls    d4,d0   ; m00*x
        move.w  (a2)+,d1
        muls    d5,d1   ; m01*y
        add.l   d1,d0
        move.w  (a2)+,d1
        muls    d6,d1   ; m02*z
        add.l   d1,d0
        FP2I14FP d0     ; new x, convert to integer with extra precision

        ; Calculate new y = m10*x + m11*y + m12*z
        move.w  (a2)+,d1
        muls    d4,d1   ; m10*x
        move.w  (a2)+,d2
        muls    d5,d2   ; m11*y
        add.l   d2,d1
        move.w  (a2)+,d2
        muls    d6,d2   ; m12*z
        add.l   d2,d1
        FP2I14FP d1     ; new y, convert to integer with extra precision

        ; Calculate new z = m20*x + m21*y + m22*z
        move.w  (a2)+,d2
        muls    d4,d2   ; m20*x
        move.w  (a2)+,d3
        muls    d5,d3   ; m21*y
        add.l   d3,d2
        move.w  (a2)+,d3
        muls    d6,d3   ; m22*z
        add.l   d3,d2
        FP2I14  d2      ; new z, convert to integer

        ; Perspective projection
        ext.l   d0
        ext.l   d1
        add.w   Dist(pc),d2
        asl.l   #PERSP_SHIFT,d0
        asl.l   #PERSP_SHIFT,d1
        divs    d2,d1
        divs    d2,d0

        ; Center in screen coordinates
        add.w   #(SCREEN_W/2-60)<<FP_BITS,d0
        add.w   #(SCREEN_H/2)<<FP_BITS,d1

        ; Write transformed data
        move.w  d0,(a1)+
        move.w  d1,(a1)+
        dbf     d7,.l

        rts

********************************************************************************
; BuildRotationMatrix - Calculates combined rotation matrix from XYZ angles
; Matrix = RotZ * RotX * RotY (applied in order: Y, then X, then Z)
; Using YXZ order (computer graphics standard)
;
; Matrix format (row-major):
;   m00 m01 m02
;   m10 m11 m12
;   m20 m21 m22
;-------------------------------------------------------------------------------
BuildRotationMatrix:
        lea     Matrix,a0
        lea     Sin,a1
        lea     Cos,a2
        movem.w Rot(pc),a3-a5 ; a3=ZRot, a4=YRot, a5=XRot

        move.w  (a1,a3),d0 ; sinZ
        move.w  (a2,a3),d1 ; cosZ
        move.w  (a1,a4),d2 ; sinY
        move.w  (a2,a4),d3 ; cosY
        move.w  (a1,a5),d4 ; sinX
        move.w  (a2,a5),d5 ; cosX

        ; Calculate combined rotation matrix elements for YXZ order
        ; m00 = cosY*cosZ - sinY*sinX*sinZ
        move.w  d3,d6
        FPMULS14 d1,d6  ; cosY*cosZ
        move.w  d2,d7
        FPMULS14 d4,d7  ; sinY*sinX
        FPMULS14 d0,d7  ; *sinZ
        sub.w   d7,d6
        move.w  d6,(a0)+

        ; m01 = -cosX*sinZ
        move.w  d5,d6
        FPMULS14 d0,d6
        neg.w   d6
        move.w  d6,(a0)+

        ; m02 = sinY*cosZ + cosY*sinX*sinZ
        move.w  d2,d6
        FPMULS14 d1,d6  ; sinY*cosZ
        move.w  d3,d7
        FPMULS14 d4,d7  ; cosY*sinX
        FPMULS14 d0,d7  ; *sinZ
        add.w   d7,d6
        move.w  d6,(a0)+

        ; m10 = cosY*sinZ + sinY*sinX*cosZ
        move.w  d3,d6
        FPMULS14 d0,d6  ; cosY*sinZ
        move.w  d2,d7
        FPMULS14 d4,d7  ; sinY*sinX
        FPMULS14 d1,d7  ; *cosZ
        add.w   d7,d6
        move.w  d6,(a0)+

        ; m11 = cosX*cosZ
        move.w  d5,d6
        FPMULS14 d1,d6
        move.w  d6,(a0)+

        ; m12 = sinY*sinZ - cosY*sinX*cosZ
        move.w  d2,d6
        FPMULS14 d0,d6  ; sinY*sinZ
        move.w  d3,d7
        FPMULS14 d4,d7  ; cosY*sinX
        FPMULS14 d1,d7  ; *cosZ
        sub.w   d7,d6
        move.w  d6,(a0)+

        ; m20 = -cosX*sinY
        move.w  d5,d6
        FPMULS14 d2,d6  ; cosX*sinY
        neg.w   d6
        move.w  d6,(a0)+

        ; m21 = sinX
        move.w  d4,(a0)+

        ; m22 = cosX*cosY
        move.w  d5,d6
        FPMULS14 d3,d6
        move.w  d6,(a0)+

        rts

; ------------- a0 - Screen buffer

Clear:
        bsr     WaitBlitter
        move.w   #H_PAD,bltdmod(a6)
        move.l  #$01000000,bltcon0(a6)

        move.l  DrawScreen(pc),a0
        add.l   #(SCREEN_BW*SCREEN_H),a0
        move.l  a0,bltdpt(a6)
        
        move.w  #((SCREEN_H*BLITTER_BITPLANES)&1023)*64+(SCREEN_BW-H_PAD)/2,bltsize(a6)
        rts

SwapBuffers:
        lea     ScreenBuffers(pc),a0
        movem.l (a0),d0-d1
        exg     d0,d1
        movem.l d0-d1,(a0)
; Set bpl pointers in copper
        lea     CopBplPt+2,a1
        moveq   #BPLS-1,d7
.bpll:  move.l  d1,d0
        swap    d0
        move.w  d0,(a1) ; high word of address
        move.w  d1,4(a1) ; low word of address
        addq.w  #8,a1   ; next copper instruction
        add.l   #SCREEN_BPL,d1 ; next bpl ptr
        dbf     d7,.bpll
        rts

Draw:
        bsr     WaitBlitter
        
        move.l  DrawScreen(pc),a0
        ; set pointer to the 2nd bitplane
        add.l   #(SCREEN_BW*SCREEN_H),a0

        bsr     PlotPoints
        bsr     FillScreen
        rts

PlotPoints:
        bsr     InitDrawLine

        move.l  DrawScreen(pc),a3
        ; set pointer to the 2nd bitplane
        add.l   #(SCREEN_BW*SCREEN_H),a3

        lea     Faces,a1
        lea     PointsTransformed,a2
        move.w  #FACE_COUNT-1,d7
.face
        move.w  (a1)+,d0 ; Bitplane
        lea     (a3,d0),a0

        move.w  (a1),d0 ; Vert 1
        movem.w (a2,d0),d0-d1
        move.w  2(a1),d2 ; Vert 2
        movem.w (a2,d2),d2-d3
        move.w  4(a1),d4 ; Vert 3
        movem.w (a2,d4),d4-d5

        ; Backface cull:
        ; (y1-y2)*(x2-x3)-(y2-y3)*(x1-x2)
        sub.w   d2,d0   ; d0 = x1-x2
        sub.w   d4,d2   ; d2 = x2-x3
        sub.w   d3,d1   ; d1 = y1-y2
        sub.w   d5,d3   ; d5 = y2-y3
        asr.w   #4,d0
        asr.w   #4,d1
        asr.w   #4,d2
        asr.w   #4,d3
        muls    d1,d2   ; d2 = (y1-y2)*(x2-x3)
        muls    d3,d0   ; d0 = (y2-y3)*(x1-x2)
        sub.w   d2,d0   ; d0 = (y1-y2)*(x2-x3)-(y2-y3)*(x1-x2)
        bgt     .front
        tst.w -2(a1)
        beq     .skip
        adda.w  #SCREEN_BPL,a0
.front

        ; d4-d5 still ok, can we use this?
        move.w  4(a1),d0 ; Vert 3
        movem.w (a2,d0),d0-d1

        ; movem.w (POINT_COUNT-1)*4(a2),d0-d1 ; start at last vertex to close loop
        move.w  #3-1,d6
.line
        move.w  (a1)+,d2 ; Next vert
        movem.w (a2,d2),d2-d3
        BLIT_WAIT
        bsr     SubPixelBlitterEdgeLine
        move.w  d2,d0   ; end point becomes next start point
        move.w  d3,d1
        dbf     d6,.line

        dbf     d7,.face

        rts
.skip
        adda.w  #3*2,a1
        dbf     d7,.face
        rts

; fill the screen (and so the shape) with the blitter, starting from the ⬇bottom ⬆up
FillScreen:
        BLIT_WAIT
        
        move.w  #ANBNC!ANBC!ABNC!ABC!DEST!SRCA,bltcon0(a6) ; bltcon0: Copy channel A -> D
        move.w  #BLITREVERSE!FILL_XOR,bltcon1(a6) ; bltcon1: Enable fill and descending mode (fill must be DESC)
        move.w   #H_PAD,bltamod(a6) ; set modulo to H_PAD bytes
        move.w   #H_PAD,bltdmod(a6) ; set modulo to H_PAD bytes
    
        move.l  DrawScreen(pc),a0
        ; set pointer starting from the 2nd bitplane
        add.w   #(SCREEN_BW*SCREEN_H)-H_PAD,a0

        ; we need to flill only 3 blitplanes from the starting offset at a0
        lea     (SCREEN_BW*SCREEN_H*BLITTER_BITPLANES)-2(a0),a1

        move.l  a1,bltapt(a6) ; Same address for source and dest
        move.l  a1,bltdpt(a6)
        move.w  #SCREEN_H*BLITTER_BITPLANES*64+(SCREEN_BW-H_PAD)/2,bltsize(a6) ; Fill whole screen
        rts

; DrawLine settings
LINE_XOR = 1            ; Use XOR minterm
LINE_ONEDOT = 1         ; Use one-dot mode for blitter fill

; Prepare common blit regs for line draw
;-------------------------------------------------------------------------------
InitDrawLine:
        BLIT_WAIT
        move.w  #SCREEN_BW,bltcmod(a6)
        move.l  #-$8000,bltbdat(a6)
        move.l  #-1,bltafwm(a6)
        rts

********************************************************************************
; Draw subpixelled blitter edge line for blitter area fill
;
; The routine assumes that the blitter is idle when called
; The routine will exit with the blitter active
;
; in	d0.w	x0 in fixed point
;	d1.w	y0 in fixed point
;	d2.w	x1 in fixed point
;	d3.w	y1 in fixed point
;	d4.w	bytes per row in bitplane
;	a0	bitplane
;	a6	$dff000
;-------------------------------------------------------------------------------
SubPixelBlitterEdgeLine:
        movem.l d2-d7/a0-a1,-(sp)

        ; move.w  d4,a1
        move.w  #SCREEN_BW,a1

        cmp.w   d1,d3
        bgt.s   .downward
        beq     .done
        exg     d0,d2
        exg     d1,d3
.downward

        cmp.w   d0,d2
        blt     .leftWard

        move.w  d2,d6
        move.w  d3,d7

        sub.w   d0,d2
        sub.w   d1,d3

        cmp.w   d2,d3
        ble     .rightWard_xMajor

.rightWard_yMajor
        move.w  #SubPixelBlitterEdgeLine_Mask,d4
        move.w  #SubPixelBlitterEdgeLine_Mask,d5
        sub.w   d0,d4
        sub.w   d1,d5
        and.w   #SubPixelBlitterEdgeLine_Mask,d4 ; prestep_x = SubPixelBlitterEdgeLine_Mask - (x0 & SubPixelBlitterEdgeLine_Mask)
        and.w   #SubPixelBlitterEdgeLine_Mask,d5 ; prestep_y = SubPixelBlitterEdgeLine_Mask - (y0 & SubPixelBlitterEdgeLine_Mask)

        asr.w   #FP_BITS,d0 ; start_x = x0 >> SubPixelBlitterEdgeLine_Bits
        asr.w   #FP_BITS,d1 ; start_y = y0 >> SubPixelBlitterEdgeLine_Bits
        subq.w  #1,d1

        neg.w   d3

        muls.w  d2,d5
        muls.w  d3,d4

        lsl.w   #FP_BITS,d2
        lsl.w   #FP_BITS,d3

        add.w   d5,d4   ; bltapt = dx*prestep_y-dy*prestep_x

        move.w  d2,bltbmod(a6) ; bltbmod = dx<<SubPixelBlitterEdgeLine_Bits

        add.w   d2,d3
        move.w  d3,bltamod(a6) ; bltamod = (dx-dy)<<SubPixelBlitterEdgeLine_Bits

        move.w  d4,bltapt+2(a6)

        asr.w   #FP_BITS,d7 ; end_y = (y1 >> SubPixelBlitterEdgeLine_Bits)
        sub.w   d1,d7   ; line_length = end_y - start_y

        move.w  #0,d6
        or.w    #BLTCON1F_SING|BLTCON1F_LINE,d6
        tst.w   d4
        bpl.s   .rightWard_yMajor_positiveGradient
        or.w    #BLTCON1F_SIGN,d6
.rightWard_yMajor_positiveGradient
        move.w  d6,bltcon1(a6)

        move.w  a1,d3
        mulu.w  d1,d3
        add.l   d3,a0
        move.w  d0,d3
        asr.w   #4,d3
        add.w   d3,d3
        add.w   d3,a0
        move.l  a0,bltcpt(a6)
        move.l  #blitter_temp_output_word,bltdpt(a6)

        move.w  d0,d2
        and.w   #$f,d2
        ror.w   #4,d2

        or.w    #BLTCON0F_USEA|BLTCON0F_USEC|BLTCON0F_USED|LINE_MINTERM,d2
        move.w  d2,bltcon0(a6)
        move.w  a1,bltcmod(a6)
        move.w  a1,bltdmod(a6)

        lsl.w   #6,d7
        addq.w  #2,d7
        move.w  d7,bltsize(a6)

        bra     .done

.leftWard
        move.w  d2,d6
        move.w  d3,d7

        sub.w   d0,d2
        sub.w   d1,d3
        neg.w   d2

        cmp.w   d2,d3
        ble     .leftWard_xMajor

.leftWard_yMajor
        move.w  d0,d4
        move.w  #SubPixelBlitterEdgeLine_Mask,d5
        and.w   #SubPixelBlitterEdgeLine_Mask,d4
        sub.w   d1,d5
        subq.w  #1,d4   ; prestep_x = (x0 & SubPixelBlitterEdgeLine_Mask) - 1
        and.w   #SubPixelBlitterEdgeLine_Mask,d5 ; prestep_y = SubPixelBlitterEdgeLine_Mask - (y0 & SubPixelBlitterEdgeLine_Mask)

        asr.w   #FP_BITS,d0 ; start_x = x0 >> SubPixelBlitterEdgeLine_Bits
        asr.w   #FP_BITS,d1 ; start_y = y0 >> SubPixelBlitterEdgeLine_Bits
        subq.w  #1,d1

        neg.w   d3

        muls.w  d2,d5
        muls.w  d3,d4

        lsl.w   #FP_BITS,d2
        lsl.w   #FP_BITS,d3

        add.w   d5,d4   ; bltapt = dx*prestep_y-dy*prestep_x

        move.w  d2,bltbmod(a6) ; bltbmod = dx<<SubPixelBlitterEdgeLine_Bits

        add.w   d2,d3
        move.w  d3,bltamod(a6) ; bltamod = (dx-dy)<<SubPixelBlitterEdgeLine_Bits

        move.w  d4,bltapt+2(a6)

        asr.w   #FP_BITS,d7 ; end_y = (y1 >> SubPixelBlitterEdgeLine_Bits)
        sub.w   d1,d7   ; line_length = end_y - start_y

        move.w  #BLTCON1F_SUL,d6
        or.w    #BLTCON1F_SING|BLTCON1F_LINE,d6
        tst.w   d4
        bpl.s   .leftWard_yMajor_positiveGradient
        or.w    #BLTCON1F_SIGN,d6
.leftWard_yMajor_positiveGradient
        move.w  d6,bltcon1(a6)

        move.w  a1,d3
        mulu.w  d1,d3
        add.l   d3,a0
        move.w  d0,d3
        asr.w   #4,d3
        add.w   d3,d3
        add.w   d3,a0
        move.l  a0,bltcpt(a6)
        move.l  #blitter_temp_output_word,bltdpt(a6)

        move.w  d0,d2
        and.w   #$f,d2
        ror.w   #4,d2

        or.w    #BLTCON0F_USEA|BLTCON0F_USEC|BLTCON0F_USED|LINE_MINTERM,d2
        move.w  d2,bltcon0(a6)

        move.w  a1,bltcmod(a6)
        move.w  a1,bltdmod(a6)

        lsl.w   #6,d7
        addq.w  #2,d7
        move.w  d7,bltsize(a6)

        bra     .done
        nop

.rightWard_xMajor
        move.w  #SubPixelBlitterEdgeLine_Mask,d4
        move.w  #SubPixelBlitterEdgeLine_Mask,d5
        sub.w   d0,d4
        sub.w   d1,d5
        and.w   #SubPixelBlitterEdgeLine_Mask,d4 ; prestep_x = SubPixelBlitterEdgeLine_Mask - (x0 & SubPixelBlitterEdgeLine_Mask)
        and.w   #SubPixelBlitterEdgeLine_Mask,d5 ; prestep_y = SubPixelBlitterEdgeLine_Mask - (y0 & SubPixelBlitterEdgeLine_Mask)

        asr.w   #FP_BITS,d0
        asr.w   #FP_BITS,d1

        subq.w  #1,d0   ; start_x = (x0 >> SubPixelBlitterEdgeLine_Bits) - 1
        subq.w  #1,d1   ; start_y = (y0 >> SubPixelBlitterEdgeLine_Bits) - 1

        neg.w   d2

        move.w  d3,-(sp)
        move.w  d2,-(sp)

        muls.w  d2,d5
        muls.w  d3,d4

        lsl.w   #FP_BITS,d2
        lsl.w   #FP_BITS,d3

        add.w   d5,d4   ; bltapt = dy*prestep_x - dx*prestep_y

        move.w  d3,bltbmod(a6) ; bltbmod = dy<<SubPixelBlitterEdgeLine_Bits

        add.w   d2,d3
        move.w  d3,bltamod(a6) ; bltamod = (dy-dx)<<SubPixelBlitterEdgeLine_Bits

        move.w  d4,bltapt+2(a6)

        move.w  a1,d3
        mulu.w  d1,d3
        add.l   d3,a0
        move.w  d0,d3
        asr.w   #4,d3
        add.w   d3,d3
        add.w   d3,a0
        move.l  a0,bltcpt(a6)
        move.l  #blitter_temp_output_word,bltdpt(a6)

        move.w  d0,d2
        and.w   #$f,d2
        ror.w   #4,d2

        or.w    #BLTCON0F_USEA|BLTCON0F_USEC|BLTCON0F_USED|LINE_MINTERM,d2
        move.w  d2,bltcon0(a6)
        move.w  a1,bltcmod(a6)
        move.w  a1,bltdmod(a6)

        move.w  d6,d2
        move.w  d7,d3
        and.w   #SubPixelBlitterEdgeLine_Mask,d2
        and.w   #SubPixelBlitterEdgeLine_Mask,d3
        subq.w  #1,d2
        subq.w  #1,d3

        muls.w  (sp)+,d3
        muls.w  (sp)+,d2

        move.w  d6,d7
        asr.w   #FP_BITS,d7 ; end_x = (x1 >> SubPixelBlitterEdgeLine_Bits)
        sub.w   d0,d7   ; line_length = end_x - start_x

        add.l   d2,d3
        ble.s   .rightWard_xMajor_nExtraPixel
        addq.w  #1,d7
.rightWard_xMajor_nExtraPixel

        move.w  #BLTCON1F_SUD,d6
        or.w    #BLTCON1F_SING|BLTCON1F_LINE,d6
        tst.w   d4
        bpl.s   .rightWard_xMajor_positiveGradient
        or.w    #BLTCON1F_SIGN,d6
.rightWard_xMajor_positiveGradient
        move.w  d6,bltcon1(a6)

        lsl.w   #6,d7
        addq.w  #2,d7
        move.w  d7,bltsize(a6)

        bra     .done

.leftWard_xMajor
        move.w  d0,d4
        move.w  #SubPixelBlitterEdgeLine_Mask,d5
        and.w   #SubPixelBlitterEdgeLine_Mask,d4
        sub.w   d1,d5
        subq.w  #1,d4   ; prestep_x = (x0 & SubPixelBlitterEdgeLine_Mask) - 1
        and.w   #SubPixelBlitterEdgeLine_Mask,d5 ; prestep_y = SubPixelBlitterEdgeLine_Mask - (y0 & SubPixelBlitterEdgeLine_Mask)

        asr.w   #FP_BITS,d0
        asr.w   #FP_BITS,d1

        addq.w  #1,d0   ; start_x = (x0 >> SubPixelBlitterEdgeLine_Bits) + 1
        subq.w  #1,d1   ; start_y = (y0 >> SubPixelBlitterEdgeLine_Bits) - 1

        neg.w   d2

        move.w  d3,-(sp)
        move.w  d2,-(sp)

        muls.w  d2,d5
        muls.w  d3,d4

        lsl.w   #FP_BITS,d2
        lsl.w   #FP_BITS,d3

        add.w   d5,d4   ; bltapt = dy*prestep_x - dx*prestep_y

        move.w  d3,bltbmod(a6) ; bltbmod = dy<<SubPixelBlitterEdgeLine_Bits

        add.w   d2,d3
        move.w  d3,bltamod(a6) ; bltamod = (dy-dx)<<SubPixelBlitterEdgeLine_Bits

        move.w  d4,bltapt+2(a6)

        move.w  a1,d3
        mulu.w  d1,d3
        add.l   d3,a0
        move.w  d0,d3
        asr.w   #4,d3
        add.w   d3,d3
        add.w   d3,a0
        move.l  a0,bltcpt(a6)
        move.l  #blitter_temp_output_word,bltdpt(a6)

        move.w  d0,d2
        and.w   #$f,d2
        ror.w   #4,d2

        or.w    #BLTCON0F_USEA|BLTCON0F_USEC|BLTCON0F_USED|LINE_MINTERM,d2
        move.w  d2,bltcon0(a6)

        move.w  #SubPixelBlitterEdgeLine_Mask,d2
        sub.w   d6,d2
        move.w  d7,d3
        and.w   #SubPixelBlitterEdgeLine_Mask,d2
        and.w   #SubPixelBlitterEdgeLine_Mask,d3
        subq.w  #1,d3

        muls.w  (sp)+,d3
        muls.w  (sp)+,d2

        move.w  d6,d7
        asr.w   #FP_BITS,d7 ; end_x = (x1 >> SubPixelBlitterEdgeLine_Bits)
        sub.w   d0,d7
        neg.w   d7      ; line_length = start_x - end_x

        add.l   d2,d3
        ble.s   .leftWard_xMajor_nExtraPixel
        addq.w  #1,d7
.leftWard_xMajor_nExtraPixel

        move.w  #BLTCON1F_SUD|BLTCON1F_AUL,d6
        or.w    #BLTCON1F_SING|BLTCON1F_LINE,d6
        tst.w   d4
        bpl.s   .leftWard_xMajor_positiveGradient
        or.w    #BLTCON1F_SIGN,d6
.leftWard_xMajor_positiveGradient
        move.w  d6,bltcon1(a6)

        move.w  a1,bltcmod(a6)
        move.w  a1,bltdmod(a6)

        lsl.w   #6,d7
        addq.w  #2,d7
        move.w  d7,bltsize(a6)

        bra     .done

.done
        movem.l (sp)+,d2-d7/a0-a1
        rts

; ------------- Vars
Vars:

Rot:
ZRot:   dc.w    0
YRot:   dc.w    0
XRot:   dc.w    0

Frame:  dc.w    0

ScreenBuffers:
DrawScreen: dc.l Screen1
ViewScreen: dc.l Screen2

Matrix: ds.w    9       ; 3x3 rotation matrix (m00-m22)

Dist:   dc.w    180

; macro to ease the creation of the sequence as:
; bitplane index where to render the face
; index 0 face coordinate
; index 1 face coordinate
; index 2 face coordinate
FACE    macro
        ; using -1 because .OBJ formats have the faces with index that starts with 1 and not 0
        dc.w    \1*SCREEN_BPL,(\2-1)*4,(\3-1)*4,(\4-1)*4
        endm

Points:
        dc.w    0,-32,55
        dc.w    -48,32,27
        dc.w    -48,-32,27
        dc.w    -48,32,-27
        dc.w    -48,-32,-27
        dc.w    0,32,-55
        dc.w    0,-32,-55
        dc.w    0,-64,0
        dc.w    0,64,0
        dc.w    48,32,-27
        dc.w    48,-32,-27
        dc.w    48,32,27
        dc.w    48,-32,27
        dc.w    0,32,55

; Bitplane index, vert indices
Faces:
        ; top cap
        FACE 0,2,9,14
        FACE 1,4,9,2
        FACE 0,6,9,4
        FACE 1,10,9,6
        FACE 0,12,9,10
        FACE 1,14,9,12

        ; middle carousel
        FACE 1,1,3,14
        FACE 0,3,2,14
        FACE 1,3,5,2
        FACE 0,5,4,2
        FACE 1,13,1,12
        FACE 0,1,14,12
        FACE 1,5,7,4
        FACE 0,7,6,4
        FACE 1,11,13,10
        FACE 0,13,12,10
        FACE 1,7,11,6
        FACE 0,11,10,6

        ; bottom cap
        FACE 1,1,8,3
        FACE 0,13,8,1
        FACE 1,5,8,7
        FACE 0,3,8,5;
        FACE 1,11,8,13
        FACE 0,7,8,11
        
; ------------- Logo sprite

initial_pause_sprite_counter:
        dc.w    0

init_logo_sprite:
        movem.l d0-a1,-(sp)

        ; poke sprite bitplane/s
	LEA	CopSprPt,a1
        
        ; sprite_0
        move.l	#logo_sprite_0,d0
	move.w	d0,6(a1)
	swap	d0
	move.w	d0,2(a1)
        
        ; sprite_1
        move.l	#logo_sprite_1,d0
	add.w	#8,a1
	move.w	d0,6(a1)
	swap	d0
	move.w	d0,2(a1)

        ; sprite_2
        move.l	#logo_sprite_2,d0
	add.w	#8,a1
	move.w	d0,6(a1)
	swap	d0
	move.w	d0,2(a1)

        ; sprite_3
        move.l	#logo_sprite_3,d0
	add.w	#8,a1
	move.w	d0,6(a1)
	swap	d0
	move.w	d0,2(a1)

        ; sprite_4
        move.l  #logo_sprite_4,d0
	addq.w	#8,a1
	move.w	d0,6(a1)
	swap	d0
	move.w	d0,2(a1)

        ; sprite_5
        move.l	#logo_sprite_5,d0
	addq.w	#8,a1
	move.w	d0,6(a1)
	swap	d0
	move.w	d0,2(a1)

        ; sprite_6
        move.l	#logo_sprite_6,d0
	addq.w	#8,a1
	move.w	d0,6(a1)
	swap	d0
	move.w	d0,2(a1)

        ; sprite_7
        move.l	#logo_sprite_7,d0
	addq.w	#8,a1
	move.w	d0,6(a1)
	swap	d0
	move.w	d0,2(a1)

        movem.l (sp)+,d0-a1

        rts

move_logo_sprite:
        cmp.w   #INITIAL_PAUSE_SPRITE,initial_pause_sprite_counter
        beq     .continue_0
        addq.w  #1,initial_pause_sprite_counter
        rts

.continue_0:
        movem.l a4,-(sp)
        lea     logo_sprite_0,a4
        cmpi.b  #END_VPOS,(a4)
        beq     .continue_1
        ; move VSTART +1 pixel down
        addq.b  #1,(a4)
        ; shift from vstart to vstop
        add.w   #2,a4
        ; move VSTOP +1 pixel down
        addq.b  #1,(a4)

.continue_1:
        lea     logo_sprite_1,a4
        cmpi.b  #END_VPOS,(a4)
        beq     .continue_2
        ; move VSTART +1 pixel down
        addq.b  #1,(a4)
        ; shift from vstart to vstop
        add.w   #2,a4
        ; move VSTOP +1 pixel down
        addq.b  #1,(a4)

.continue_2:
        lea     logo_sprite_2,a4
        cmpi.b  #END_VPOS,(a4)
        beq     .continue_3
        ; move VSTART +1 pixel down
        addq.b  #1,(a4)
        ; shift from vstart to vstop
        add.w   #2,a4
        ; move VSTOP +1 pixel down
        addq.b  #1,(a4)

.continue_3:
        lea     logo_sprite_3,a4
        cmpi.b  #END_VPOS,(a4)
        beq     .continue_4
        ; move VSTART +1 pixel down
        addq.b  #1,(a4)
        ; shift from vstart to vstop
        add.w   #2,a4
        ; move VSTOP +1 pixel down
        addq.b  #1,(a4)

.continue_4:
        lea     logo_sprite_4,a4
        cmpi.b  #END_VPOS,(a4)
        beq     .continue_5
        ; move VSTART +1 pixel down
        addq.b  #1,(a4)
        ; shift from vstart to vstop
        add.w   #2,a4
        ; move VSTOP +1 pixel down
        addq.b  #1,(a4)

.continue_5:
        lea     logo_sprite_5,a4
        cmpi.b  #END_VPOS,(a4)
        beq     .continue_6
        ; move VSTART +1 pixel down
        addq.b  #1,(a4)
        ; shift from vstart to vstop
        add.w   #2,a4
        ; move VSTOP +1 pixel down
        addq.b  #1,(a4)

.continue_6:
        lea     logo_sprite_6,a4
        cmpi.b  #END_VPOS,(a4)
        beq     .continue_7
        ; move VSTART +1 pixel down
        addq.b  #1,(a4)
        ; shift from vstart to vstop
        add.w   #2,a4
        ; move VSTOP +1 pixel down
        addq.b  #1,(a4)

.continue_7:
        lea     logo_sprite_7,a4
        cmpi.b  #END_VPOS,(a4)
        beq     .continue_exit
        ; move VSTART +1 pixel down
        addq.b  #1,(a4)
        ; shift from vstart to vstop
        add.w   #2,a4
        ; move VSTOP +1 pixel down
        addq.b  #1,(a4)

.continue_exit:
        movem.l (sp)+,a4
        rts

; ------------- HUE shift color for all the glenz faces

color_hue_shift_index:  
        dc.w    0

hue_shift_delay_counter:
        dc.w    0

main_hue_shift:
        cmpi.w  #BETWEEN_HUE_COLOR_SHIFT_PAUSE,hue_shift_delay_counter
        bge     .shift
        ble     .initial_delay

.shift:
        ; reset the counter of wait between each color shift
        clr     hue_shift_delay_counter

        movem.l d0/a0-a5,-(sp)

        ; move all the colors shift arrays in aN
        lea     gradient_0_start,a0
        lea     gradient_1_start,a1
        lea     gradient_2_start,a2
        lea     gradient_3_start,a3
        lea     gradient_4_start,a4
        lea     color_hue_shift_index,a5

        ; move the index into dN
        move.w  (a5),d0
        
        ; assign the correct color shift to the colors registers
        move.w  (a0,d0),color02(a6)
        move.w  (a1,d0),color03(a6)
        move.w  (a2,d0),color04(a6)
        move.w  (a3,d0),color05(a6)
        move.w  (a4,d0),color12(a6)
        move.w  (a4,d0),color13(a6)
        
        ; needs to be *2 for word offset
        addq.w  #2,d0
        move.w  d0,(a5)
        ; we have 255 colors max to shift
        cmp.w   #$200,(a5)
        bge     .reset_color_hue
        bra     .continue

.reset_color_hue:
        move.w  #0,(a5)

.continue:
        movem.l (sp)+,d0/a0-a5
        bra     .exit

.initial_delay:
        addq.w  #1,hue_shift_delay_counter

.exit:
        rts

gradient_0_start:
	dc.w $f00,$f00,$f00,$f10,$f10,$f10,$f20,$f20
	dc.w $f20,$f30,$f30,$f40,$f40,$f40,$f50,$f50
	dc.w $f50,$f60,$f60,$f60,$f70,$f70,$f80,$f80
	dc.w $f80,$f90,$f90,$f90,$fa0,$fa0,$fa0,$fb0
	dc.w $fb0,$fb0,$fc0,$fc0,$fd0,$fd0,$fd0,$fe0
	dc.w $fe0,$fe0,$ff0,$ff0,$ff0,$ff0,$ff0,$ef0
	dc.w $ef0,$df0,$df0,$cf0,$cf0,$bf0,$bf0,$af0
	dc.w $af0,$9f0,$9f0,$8f0,$8f0,$8f0,$7f0,$7f0
	dc.w $6f0,$6f0,$5f0,$5f0,$4f0,$4f0,$3f0,$3f0
	dc.w $2f0,$2f0,$1f0,$1f0,$0f0,$0f0,$0f0,$0f0
	dc.w $0f0,$0f1,$0f1,$0f1,$0f2,$0f2,$0f2,$0f3
	dc.w $0f3,$0f4,$0f4,$0f4,$0f5,$0f5,$0f5,$0f6
	dc.w $0f6,$0f6,$0f7,$0f7,$0f8,$0f8,$0f8,$0f9
	dc.w $0f9,$0f9,$0fa,$0fa,$0fa,$0fb,$0fb,$0fb
	dc.w $0fc,$0fc,$0fd,$0fd,$0fd,$0fe,$0fe,$0fe
	dc.w $0ff,$0ff,$0ff,$0ff,$0ff,$0ef,$0ef,$0ef
	dc.w $0df,$0df,$0cf,$0cf,$0cf,$0bf,$0bf,$0af
	dc.w $0af,$0af,$09f,$09f,$08f,$08f,$08f,$07f
	dc.w $07f,$07f,$06f,$06f,$05f,$05f,$05f,$04f
	dc.w $04f,$03f,$03f,$03f,$02f,$02f,$01f,$01f
	dc.w $01f,$00f,$00f,$00f,$00f,$00f,$10f,$10f
	dc.w $10f,$20f,$20f,$20f,$30f,$30f,$30f,$40f
	dc.w $40f,$40f,$50f,$50f,$50f,$60f,$60f,$60f
	dc.w $70f,$70f,$80f,$80f,$80f,$90f,$90f,$90f
	dc.w $a0f,$a0f,$a0f,$b0f,$b0f,$b0f,$c0f,$c0f
	dc.w $c0f,$d0f,$d0f,$d0f,$e0f,$e0f,$e0f,$f0f
	dc.w $f0f,$f0f,$f0f,$f0f,$f0e,$f0e,$f0e,$f0d
	dc.w $f0d,$f0d,$f0c,$f0c,$f0c,$f0b,$f0b,$f0b
	dc.w $f0a,$f0a,$f0a,$f09,$f09,$f09,$f08,$f08
	dc.w $f08,$f07,$f07,$f06,$f06,$f06,$f05,$f05
	dc.w $f05,$f04,$f04,$f04,$f03,$f03,$f03,$f02
	dc.w $f02,$f02,$f01,$f01,$f01,$f00,$f00,$f00
gradient_0_end:
        dc.w 0,0

gradient_1_start:
	dc.w $e00,$e00,$e00,$e10,$e10,$e10,$e20,$e20
	dc.w $e20,$e30,$e30,$e30,$e40,$e40,$e40,$e50
	dc.w $e50,$e50,$e60,$e60,$e60,$e70,$e70,$e70
	dc.w $e80,$e80,$e80,$e90,$e90,$e90,$ea0,$ea0
	dc.w $ea0,$eb0,$eb0,$eb0,$ec0,$ec0,$ec0,$ed0
	dc.w $ed0,$ed0,$ee0,$ee0,$ee0,$ee0,$ee0,$de0
	dc.w $de0,$ce0,$ce0,$be0,$be0,$be0,$ae0,$ae0
	dc.w $9e0,$9e0,$8e0,$8e0,$7e0,$7e0,$7e0,$6e0
	dc.w $6e0,$5e0,$5e0,$4e0,$4e0,$3e0,$3e0,$3e0
	dc.w $2e0,$2e0,$1e0,$1e0,$0e0,$0e0,$0e0,$0e0
	dc.w $0e0,$0e1,$0e1,$0e1,$0e2,$0e2,$0e2,$0e3
	dc.w $0e3,$0e3,$0e4,$0e4,$0e4,$0e5,$0e5,$0e5
	dc.w $0e6,$0e6,$0e6,$0e7,$0e7,$0e7,$0e8,$0e8
	dc.w $0e8,$0e9,$0e9,$0e9,$0ea,$0ea,$0ea,$0eb
	dc.w $0eb,$0eb,$0ec,$0ec,$0ec,$0ed,$0ed,$0ed
	dc.w $0ee,$0ee,$0ee,$0ee,$0ee,$0de,$0de,$0de
	dc.w $0ce,$0ce,$0ce,$0be,$0be,$0ae,$0ae,$0ae
	dc.w $09e,$09e,$09e,$08e,$08e,$08e,$07e,$07e
	dc.w $06e,$06e,$06e,$05e,$05e,$05e,$04e,$04e
	dc.w $04e,$03e,$03e,$02e,$02e,$02e,$01e,$01e
	dc.w $01e,$00e,$00e,$00e,$00e,$00e,$10e,$10e
	dc.w $10e,$10e,$20e,$20e,$20e,$30e,$30e,$30e
	dc.w $40e,$40e,$40e,$50e,$50e,$50e,$60e,$60e
	dc.w $60e,$70e,$70e,$70e,$80e,$80e,$80e,$90e
	dc.w $90e,$90e,$a0e,$a0e,$a0e,$b0e,$b0e,$b0e
	dc.w $c0e,$c0e,$c0e,$d0e,$d0e,$d0e,$d0e,$e0e
	dc.w $e0e,$e0e,$e0e,$e0e,$e0d,$e0d,$e0d,$e0d
	dc.w $e0c,$e0c,$e0c,$e0b,$e0b,$e0b,$e0a,$e0a
	dc.w $e0a,$e09,$e09,$e09,$e08,$e08,$e08,$e07
	dc.w $e07,$e07,$e06,$e06,$e06,$e05,$e05,$e05
	dc.w $e04,$e04,$e04,$e03,$e03,$e03,$e02,$e02
	dc.w $e02,$e01,$e01,$e01,$e01,$e00,$e00,$e00
gradient_1_end:
        dc.w 0,0

gradient_2_start:
	dc.w $800,$800,$800,$800,$800,$810,$810,$810
	dc.w $810,$810,$810,$820,$820,$820,$820,$820
	dc.w $830,$830,$830,$830,$830,$840,$840,$840
	dc.w $840,$840,$850,$850,$850,$850,$850,$860
	dc.w $860,$860,$860,$860,$870,$870,$870,$870
	dc.w $870,$870,$880,$880,$880,$880,$880,$780
	dc.w $780,$780,$780,$680,$680,$680,$680,$580
	dc.w $580,$580,$580,$480,$480,$480,$480,$380
	dc.w $380,$380,$380,$280,$280,$280,$280,$180
	dc.w $180,$180,$180,$080,$080,$080,$080,$080
	dc.w $080,$080,$080,$081,$081,$081,$081,$081
	dc.w $081,$082,$082,$082,$082,$082,$083,$083
	dc.w $083,$083,$083,$084,$084,$084,$084,$084
	dc.w $085,$085,$085,$085,$085,$086,$086,$086
	dc.w $086,$086,$087,$087,$087,$087,$087,$087
	dc.w $088,$088,$088,$088,$088,$078,$078,$078
	dc.w $078,$078,$068,$068,$068,$068,$068,$058
	dc.w $058,$058,$058,$058,$048,$048,$048,$048
	dc.w $038,$038,$038,$038,$038,$028,$028,$028
	dc.w $028,$028,$018,$018,$018,$018,$018,$008
	dc.w $008,$008,$008,$008,$008,$008,$008,$008
	dc.w $008,$108,$108,$108,$108,$108,$208,$208
	dc.w $208,$208,$208,$208,$308,$308,$308,$308
	dc.w $308,$408,$408,$408,$408,$408,$508,$508
	dc.w $508,$508,$508,$508,$608,$608,$608,$608
	dc.w $608,$708,$708,$708,$708,$708,$808,$808
	dc.w $808,$808,$808,$808,$808,$807,$807,$807
	dc.w $807,$807,$806,$806,$806,$806,$806,$805
	dc.w $805,$805,$805,$805,$805,$804,$804,$804
	dc.w $804,$804,$803,$803,$803,$803,$803,$802
	dc.w $802,$802,$802,$802,$802,$801,$801,$801
	dc.w $801,$801,$800,$800,$800,$800,$800,$800
gradient_2_end:
        dc.w 0,0
        
gradient_3_start:
	dc.w $700,$700,$700,$700,$700,$700,$710,$710
	dc.w $710,$710,$710,$710,$720,$720,$720,$720
	dc.w $720,$720,$730,$730,$730,$730,$730,$730
	dc.w $740,$740,$740,$740,$740,$740,$750,$750
	dc.w $750,$750,$750,$750,$760,$760,$760,$760
	dc.w $760,$760,$770,$770,$770,$770,$770,$670
	dc.w $670,$670,$670,$670,$570,$570,$570,$570
	dc.w $570,$470,$470,$470,$470,$470,$370,$370
	dc.w $370,$370,$370,$270,$270,$270,$270,$270
	dc.w $170,$170,$170,$170,$170,$170,$070,$070
	dc.w $070,$070,$070,$070,$070,$070,$070,$070
	dc.w $071,$071,$071,$071,$071,$072,$072,$072
	dc.w $072,$072,$073,$073,$073,$073,$073,$073
	dc.w $074,$074,$074,$074,$074,$075,$075,$075
	dc.w $075,$075,$076,$076,$076,$076,$076,$076
	dc.w $077,$077,$077,$077,$077,$067,$067,$067
	dc.w $067,$067,$067,$057,$057,$057,$057,$057
	dc.w $047,$047,$047,$047,$047,$047,$037,$037
	dc.w $037,$037,$037,$027,$027,$027,$027,$027
	dc.w $027,$017,$017,$017,$017,$017,$007,$007
	dc.w $007,$007,$007,$007,$007,$007,$007,$007
	dc.w $007,$107,$107,$107,$107,$107,$107,$107
	dc.w $207,$207,$207,$207,$207,$207,$307,$307
	dc.w $307,$307,$307,$307,$407,$407,$407,$407
	dc.w $407,$407,$507,$507,$507,$507,$507,$507
	dc.w $607,$607,$607,$607,$607,$607,$707,$707
	dc.w $707,$707,$707,$707,$707,$706,$706,$706
	dc.w $706,$706,$706,$705,$705,$705,$705,$705
	dc.w $705,$704,$704,$704,$704,$704,$704,$703
	dc.w $703,$703,$703,$703,$703,$702,$702,$702
	dc.w $702,$702,$702,$701,$701,$701,$701,$701
	dc.w $701,$701,$700,$700,$700,$700,$700,$700
gradient_3_end:
        dc.w 0,0

gradient_4_start:
	dc.w $fdd,$fdd,$fdd,$fdd,$fdd,$fed,$fec,$fec
	dc.w $fec,$fec,$fec,$fec,$feb,$feb,$feb,$feb
	dc.w $feb,$feb,$fea,$fea,$fea,$fea,$fea,$fe9
	dc.w $fe9,$fe9,$fe9,$fe9,$fe9,$fe8,$fe8,$fe8
	dc.w $fe8,$fe8,$fe8,$fe7,$fe7,$fe7,$fe7,$fe7
	dc.w $fe7,$fe6,$fe6,$ee6,$ee6,$ee6,$ef6,$ef7
	dc.w $ef7,$ef7,$ef7,$ef7,$ef8,$ef8,$ef8,$ef8
	dc.w $ef8,$ef8,$ef9,$ef9,$ef9,$ef9,$ef9,$efa
	dc.w $efa,$efa,$efa,$efa,$efb,$efb,$efb,$efb
	dc.w $efb,$efc,$efc,$efc,$efc,$efc,$efd,$dfd
	dc.w $dfd,$dfd,$dfd,$dfd,$dfe,$dfe,$dfe,$dfe
	dc.w $dfe,$dfe,$dfe,$dfe,$dfe,$dfe,$dfe,$dfe
	dc.w $dfe,$dfe,$dfe,$dfe,$dfe,$dfe,$dfe,$dfe
	dc.w $dff,$dff,$dff,$dff,$dff,$dff,$dff,$dff
	dc.w $dff,$dff,$dff,$dff,$dff,$dff,$dff,$dff
	dc.w $dff,$dff,$dff,$dff,$dff,$dff,$dff,$dff
	dc.w $dff,$dff,$dff,$dff,$dff,$dff,$dff,$dff
	dc.w $dff,$dff,$dff,$dff,$dff,$dff,$def,$def
	dc.w $def,$def,$def,$def,$def,$def,$def,$def
	dc.w $def,$def,$def,$def,$def,$def,$def,$def
	dc.w $def,$ddf,$ddf,$ddf,$ddf,$ddf,$edf,$edf
	dc.w $edf,$edf,$edf,$edf,$edf,$edf,$edf,$edf
	dc.w $edf,$edf,$edf,$edf,$edf,$edf,$edf,$edf
	dc.w $edf,$edf,$edf,$edf,$fdf,$fdf,$fdf,$fdf
	dc.w $fdf,$fdf,$fdf,$fdf,$fdf,$fdf,$fdf,$fdf
	dc.w $fdf,$fdf,$fcf,$fcf,$fcf,$fcf,$fcf,$fcf
	dc.w $fcf,$fcf,$fcf,$fcf,$fcf,$fcf,$fcf,$fcf
	dc.w $fcf,$fdf,$fdf,$fdf,$fdf,$fdf,$fdf,$fdf
	dc.w $fdf,$fdf,$fdf,$fdf,$fdf,$fdf,$fdf,$fde
	dc.w $fde,$fde,$fde,$fde,$fde,$fde,$fde,$fde
	dc.w $fde,$fde,$fde,$fde,$fde,$fde,$fde,$fde
	dc.w $fde,$fde,$fde,$fde,$fde,$fdd,$fdd,$fdd
 gradient_4_end:
        dc.w 0,0

*******************************************************************************
        SECTION COPPER,DATA_C

CopperStart:
        dc.w    fmode,0
        dc.w    diwstrt,DIW_YSTRT<<8!DIW_XSTRT
        dc.w    diwstop,(DIW_YSTOP&$ff)<<8!(DIW_XSTOP&$ff)
        dc.w    ddfstrt,(DIW_XSTRT-17)>>1&$fc+HIRES*4
        dc.w    ddfstop,(DIW_XSTRT-17+(DIW_LW>>4-1)<<4)>>1&$fc-SCROLL*8
        dc.w    bpl1mod,DIW_MOD
        dc.w    bpl2mod,DIW_MOD
        dc.w    bplcon0,(HIRES<<15)!(BPLS<<12)!(HAM<<11)!(DPF<<10)!(1<<9)!(LACE<<1)
        dc.w    bplcon2,PF1P!(PF2P<<3)!(PF2PRI<<6)
        dc.w    bplcon1,0

CopBplPt:
        rept    BPLS*2
        dc.w    bplpt+REPTN*2,0
        endr

CopSprPt:
        rept    8*2
        dc.w    sprpt+REPTN*2,0
        endr

CopPalette:
        ; bkg   00000
        dc.w    color00,$111

        ; bpln 0 00001
        dc.w    color01,$444

        ; bpln 1 00001
        ;dc.w    color02,$f00    ; << face with HUE color shift
        ;dc.w    color03,$e00    ; << face overlay background with HUE color shift

        ; bpln 2 00001
        ; dc.w    color04,$800    ; << face with HUE color shift
        ; dc.w    color05,$700    ; << face overlay background with HUE color shift
        dc.w    color06,$333    ; some line remain alone, set the color as the face in color03
        dc.w    color07,$333    ; some line remain alone, set the color as the face in color03

        ; bpln 3 01000 > 01111
        dc.w    color08,$333    ; some line remain alone, set the color as the face in color03
        dc.w    color09,$333    ; some line remain alone, set the color as the face in color03
        dc.w    color10,$fff    ; << face
        dc.w    color11,$fff    ; << face overlay background
        ; dc.w    color12,$fdd    ; << face with HUE color shift
        ; dc.w    color13,$fdd    ; << face overlay background with HUE color shift
        dc.w    color14,$000
        dc.w    color15,$000

        ; custom colors for sprite logo
        ; bpln 4 10000 > 11111
        dc.w    color16,$fff
        dc.w    color17,$222    ; logo color
        dc.w    color18,$111    ; logo color
        dc.w    color19,$888    ; logo color
        dc.w    color20,$ddd    ; logo color
        dc.w    color21,$fff    ; logo color
        dc.w    color22,$cde    ; logo color
        dc.w    color23,$acd    ; logo color
        dc.w    color24,$9ac    ; logo color
        dc.w    color25,$57a    ; logo color
        dc.w    color26,$369    ; logo color
        dc.w    color27,$148    ; logo color
        dc.w    color28,$bbb    ; logo color
        dc.w    color29,$666    ; logo color
        dc.w    color30,$037    ; logo color
        dc.w    color31,$000

        ; wait some line below the logo before changing colors from 16>31

        dc.w	$4007,$fffe
        ; default colors for glenz and text
        ; bpln 4 10000 > 11111
        dc.w    color16,$fff    ; text color
        dc.w    color17,$eee    ; overlay text color background
        dc.w    color18,$433    ; << face overlay
        dc.w    color19,$533    ; << face overlay background
        dc.w    color20,$533    ; << face overlay
        dc.w    color21,$633    ; << face overlay background
        dc.w    color22,$000
        dc.w    color23,$000
        dc.w    color24,$000
        dc.w    color25,$000
        dc.w    color26,$222    ; << face overlay
        dc.w    color27,$333    ; << face overlay background
        dc.w    color28,$411    ; << face overlay
        dc.w    color29,$633    ; << face overlay background
        dc.w    color30,$000
        dc.w    color31,$000

        ; beginning of the first line
	dc.w	$4607,$fffe
	dc.w	color00,$fff
        ; first line 3px tall
        dc.w	$4907,$fffe
	dc.w	color00,$333

        ; wait line 255 line for PAL
	dc.w	$ffdf,$fffe

        ; beginning of the second line
	dc.w	$0a07,$fffe
	dc.w	color00,$fff
        ; second line 3px tall
        dc.w	$0d07,$fffe
	dc.w	color00,$111

        dc.l    -2              ; same as $ffffffffe

CopperEnd:
         
*******************************************************************************
        SECTION SPRITE,DATA_C

logo_sprite_0:
	dc.w	$0042, $0f00	; control words
	dc.w	$0000, $0000
	dc.w	$1000, $0fff
	dc.w	$2aed, $1800
	dc.w	$4d57, $2000
	dc.w	$3a5c, $6183
	dc.w	$1188, $4424
	dc.w	$3bfb, $4004
	dc.w	$13eb, $4814
	dc.w	$33ca, $4815
	dc.w	$3b9b, $4024
	dc.w	$111a, $4474
	dc.w	$3a6b, $61a4
	dc.w	$4fff, $2000
	dc.w	$2add, $1800
	dc.w	$1000, $0fff
	dc.w	$0000, $0000
	dc.w	$0,$0   	; stop DMA

logo_sprite_1:
	dc.w	$0042, $0f80	; control words
	dc.w	$0000, $0000
	dc.w	$0000, $0000
	dc.w	$07ff, $0000
	dc.w	$1fff, $1000
	dc.w	$1c3c, $0024
	dc.w	$3bdb, $0250
	dc.w	$37eb, $0400
	dc.w	$37eb, $0000
	dc.w	$37ea, $0020
	dc.w	$37cb, $0400
	dc.w	$3b8b, $0281
	dc.w	$1c1b, $0000
	dc.w	$1fff, $1000
	dc.w	$07ff, $0000
	dc.w	$0000, $0000
	dc.w	$0000, $0000
	dc.w	$0,$0	        ; stop DMA

logo_sprite_2:
	dc.w	$004a, $0f00	; control words
	dc.w	$0000, $0000
	dc.w	$0000, $ffff
	dc.w	$dfff, $0000
	dc.w	$ffff, $0000
	dc.w	$5cbe, $8101
	dc.w	$3e7e, $c081
	dc.w	$189a, $6244
	dc.w	$bd39, $c247
	dc.w	$51c1, $842c
	dc.w	$fb93, $0424
	dc.w	$938b, $4974
	dc.w	$514b, $2b34
	dc.w	$e5ff, $0c00
	dc.w	$97ff, $3000
	dc.w	$0000, $ffff
	dc.w	$0000, $0000
	dc.w	$0,$0	        ; stop DMA

logo_sprite_3:
	dc.w	$004a, $0f80	; control words
	dc.w	$0000, $0000
	dc.w	$0000, $0000
	dc.w	$ffff, $0000
	dc.w	$ffff, $0000
	dc.w	$7e7c, $4244
	dc.w	$3d3a, $2100
	dc.w	$9d3b, $8420
	dc.w	$399b, $2000
	dc.w	$7b98, $4a13
	dc.w	$f3c0, $000b
	dc.w	$b600, $840b
	dc.w	$d724, $40ef
	dc.w	$fc00, $03ff
	dc.w	$f000, $0fff
	dc.w	$0000, $0000
	dc.w	$0000, $0000
	dc.w	$0,$0	        ; stop DMA

logo_sprite_4:
	dc.w	$0052, $0f00	; control words
	dc.w	$0000, $0000
	dc.w	$0000, $ffff
	dc.w	$fe5f, $00c0
	dc.w	$f97f, $0300
	dc.w	$f62c, $0fd3
	dc.w	$111a, $a6e7
	dc.w	$4989, $d676
	dc.w	$2bcb, $d434
	dc.w	$2b4b, $d4b4
	dc.w	$29e9, $d616
	dc.w	$288b, $d774
	dc.w	$9808, $67f7
	dc.w	$ffff, $0000
	dc.w	$ffff, $0000
	dc.w	$0000, $ffff
	dc.w	$0000, $0000
	dc.w	$0,$0	        ; stop DMA

logo_sprite_5:
	dc.w	$0052, $0f80	; control words
	dc.w	$0000, $0000
	dc.w	$0000, $0000
	dc.w	$ffc0, $003f
	dc.w	$ff00, $00ff
	dc.w	$fc00, $1218
	dc.w	$6400, $0d8b
	dc.w	$4010, $2bdb
	dc.w	$0000, $6bfb
	dc.w	$4020, $6bab
	dc.w	$8000, $abe8
	dc.w	$0400, $adcb
	dc.w	$0210, $8e18
	dc.w	$0000, $ffff
	dc.w	$0000, $ffff
	dc.w	$0000, $0000
	dc.w	$0000, $0000
	dc.w	$0,$0	        ; stop DMA

logo_sprite_6:
	dc.w	$005a, $0f00	; control words
	dc.w	$0000, $0000
	dc.w	$0008, $fff0
	dc.w	$fb54, $04b8
	dc.w	$feba, $014c
	dc.w	$341c, $cbe6
	dc.w	$5198, $ee66
	dc.w	$9fdc, $6022
	dc.w	$d078, $2f86
	dc.w	$ffb8, $0046
	dc.w	$3394, $cc6a
	dc.w	$f1b8, $0e46
	dc.w	$386c, $c796
	dc.w	$ffba, $004c
	dc.w	$bb54, $44b8
	dc.w	$0008, $fff0
	dc.w	$0000, $0000
	dc.w	$0,$0   	; stop DMA
        
logo_sprite_7:
	dc.w	$005a, $0f80	; control words
	dc.w	$0000, $0000
	dc.w	$0000, $0000
	dc.w	$0000, $fff0
	dc.w	$0000, $fff8
	dc.w	$0020, $183c
	dc.w	$0400, $d7dc
	dc.w	$2000, $fffc
	dc.w	$0400, $f43c
	dc.w	$0000, $ff9c
	dc.w	$0000, $b79c
	dc.w	$0400, $f79c
	dc.w	$4000, $503c
	dc.w	$0000, $fff8
	dc.w	$0000, $fff0
	dc.w	$0000, $0000
	dc.w	$0000, $0000
	dc.w	$0,$0	        ; stop DMA

*******************************************************************************
        SECTION ASSETS,DATA_C
        
Module:
        incbin  "short_tune.mod"
Font:
        incbin  "custom_font_8.bin"

*******************************************************************************
        BSS_C

Screen1: ds.b   SCREEN_SIZE
Screen2: ds.b   SCREEN_SIZE

blitter_temp_output_word ds.w 1

*******************************************************************************
        BSS

PointsTransformed:
        ds.b    POINT_COUNT*2

        end