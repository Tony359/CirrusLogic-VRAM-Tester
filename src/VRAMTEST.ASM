; =============================================================================
;  VRAMTEST.COM  -  Tony359's VRAM TEST for GD542x v0.2
;  Video memory tester for Cirrus Logic CL-GD542x cards.
;  https://github.com/Tony359/CirrusLogic-VRAM-Tester
;
;  Copyright (C) 2026 Tony359
;
;  This program is free software: you can redistribute it and/or modify it
;  under the terms of the GNU General Public License as published by the
;  Free Software Foundation, either version 3 of the License, or (at your
;  option) any later version.
;
;  This program is distributed in the hope that it will be useful, but
;  WITHOUT ANY WARRANTY; without even the implied warranty of
;  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
;  Public License for more details.
;
;  You should have received a copy of the GNU General Public License along
;  with this program. If not, see <https://www.gnu.org/licenses/>.
;
;  Tests all 1 MB of display memory through the Cirrus 64 KB bank window
;  (GR9 offset register, 4 KB granularity) in mode 5Fh (640x480x256,
;  packed pixels). Runs in a loop, shows a report between passes and
;  appends results to VRAMTEST.LOG in the current directory.
;
;  After the packed tests, a planar split test in mode 12h (640x480x16)
;  writes and reads one byte at a time, one plane at a time, using even and
;  odd CPU addresses. Even addresses use host data bus D0-7, odd addresses
;  D8-15, independently of the memory plane (MD lane). This separates host
;  bus faults from video memory faults.
;
;  Errors are counted per memory data line MD0-MD31 of the graphics chip.
;  Assumed mapping in packed 256-colour mode: linear byte address L lives in
;  byte lane (L AND 3), so byte lane n = MD(8n) .. MD(8n+7).
;
;  Build:   nasm -f bin -o VRAMTEST.COM VRAMTEST.ASM
;  Run:     VRAMTEST        (clean DOS boot, 386 or later CPU)
;           VRAMTEST /F     skip the Cirrus chip check
;
;  Requires a 386 or later CPU (uses 32-bit registers in real mode).
; =============================================================================

        cpu     386
        bits    16
        org     100h

%ifndef BANKS
%define BANKS 16                ; 16 x 64 KB = 1 MB
%endif
%ifndef HOLDTICKS
%define HOLDTICKS 55            ; about 3 seconds
%endif

MAXERR          equ 6           ; error details kept per pass
ERRSZ           equ 20          ; bytes per stored error
CDSECS          equ 10          ; seconds between passes
NPPAT           equ 5           ; planar test patterns
LOGMAX          equ 3800        ; log buffer size

T_CONST         equ 0
T_ADDR          equ 1
T_RAND          equ 2
T_HOLD          equ 3
T_SCROLL        equ 4

G_CONST         equ 0
G_ADDR          equ 1
G_RAND          equ 2
G_SCRV          equ 3

; -----------------------------------------------------------------------------
start:
        cld
        ; zero the uninitialised data area
        mov     di, bss_start
        mov     cx, bss_end - bss_start
        xor     al, al
        rep     stosb
        mov     byte [padc], ' '

        mov     ax, 0003h               ; clean 80x25 text screen
        int     10h

        call    parse_cmdline
        call    detect_chip
        jnc     .chip_ok
        ; unknown chip and no /F
        call    buf_reset
        mov     si, s_nochip
        call    buf_str
        mov     eax, 0
        mov     al, [chipid]
        mov     cl, 2
        call    buf_hex
        mov     si, s_nochip2
        call    buf_str
        mov     dh, 1
        call    out_line
        call    buf_reset
        mov     si, s_nochip3
        call    buf_str
        mov     dh, 2
        call    out_line
        mov     dh, 4
        call    park_cursor
        mov     ax, 4C01h
        int     21h

.chip_ok:
        call    log_header
        call    get_ticks
        mov     [t_start], eax

        call    intro_screen
        cmp     byte [abort], 0
        jne     quit_noreport

main_loop:
        inc     dword [pass]
        call    clear_pass
        call    gfx_on
        jnc     .mode_ok
        call    text_on
        call    buf_reset
        mov     si, s_nomode
        call    buf_str
        mov     dh, 1
        call    out_line
        call    log_line
        call    log_flush
        mov     dh, 3
        call    park_cursor
        mov     ax, 4C02h
        int     21h
.mode_ok:
        call    run_tests
        call    text_on
        call    accumulate
        call    show_report
        call    log_pass
        call    log_flush
        cmp     byte [abort], 0
        jne     quit
        mov     word [cd_prefix], s_next
        call    countdown
        cmp     byte [abort], 0
        jne     quit
        jmp     main_loop

quit:
        call    buf_reset
        mov     si, s_stopped
        call    buf_str
        mov     dh, 24
        call    out_line
quit_noreport:
        call    log_footer
        call    log_flush
        mov     dh, 24
        call    park_cursor
        mov     ax, 4C00h
        int     21h

; -----------------------------------------------------------------------------
; Command line: /F forces start on a chip that is not recognised
parse_cmdline:
        mov     si, 81h
        movzx   cx, byte [80h]
        jcxz    .done
.lp:    lodsb
        cmp     al, '/'
        jne     .nx
        mov     al, [si]
        or      al, 20h
        cmp     al, 'f'
        jne     .nx
        mov     byte [force], 1
.nx:    loop    .lp
.done:  ret

; -----------------------------------------------------------------------------
; Read chip ID from CR27. CF=1 if not a CL-GD542x and /F not given.
detect_chip:
        mov     dx, 3D4h
        mov     al, 27h
        out     dx, al
        inc     dx
        in      al, dx
        mov     [chipid], al
        and     al, 0FCh
        cmp     al, 88h
        jb      .unknown
        cmp     al, 9Ch
        ja      .unknown
        clc
        ret
.unknown:
        cmp     byte [force], 0
        jne     .forced
        stc
        ret
.forced:
        clc
        ret

; -----------------------------------------------------------------------------
; Intro screen with 5 s countdown
intro_screen:
        call    buf_reset
        mov     si, s_title
        call    buf_str
        mov     dh, 0
        call    out_line

        call    buf_reset
        mov     si, s_chip
        call    buf_str
        call    buf_chipname
        mov     dh, 2
        call    out_line

        mov     si, intro_lines
        mov     dh, 4
.il:    mov     bx, [si]
        test    bx, bx
        jz      .ild
        push    si
        call    buf_reset
        mov     si, bx
        call    buf_str
        call    out_line
        pop     si
        add     si, 2
        inc     dh
        jmp     .il
.ild:
        call    buf_reset
        mov     si, s_pressenter
        call    buf_str
        mov     dh, 24
        call    out_line
.wk:    mov     ah, 00h
        int     16h
        cmp     al, 0Dh
        je      .go
        cmp     al, 1Bh
        jne     .wk
        mov     byte [abort], 1
.go:    ret

; appends "CL-GD5429 (ID 9C)" or similar to the line buffer
buf_chipname:
        mov     al, [chipid]
        and     al, 0FCh
        mov     si, chipnames
.cl:    mov     ah, [si]
        test    ah, ah
        jz      .unk
        cmp     ah, al
        je      .found
        add     si, 3
        jmp     .cl
.found: mov     si, [si+1]
        call    buf_str
        jmp     .id
.unk:   mov     si, s_unknown
        call    buf_str
.id:    mov     si, s_idopen
        call    buf_str
        xor     eax, eax
        mov     al, [chipid]
        mov     cl, 2
        call    buf_hex
        mov     al, ')'
        call    buf_char
        ret

; -----------------------------------------------------------------------------
; Graphics mode 5Fh and register set-up. CF=1 if the mode could not be set.
gfx_on:
        mov     ax, 005Fh
        int     10h
        mov     ah, 0Fh
        int     10h
        cmp     al, 5Fh
        je      .set
        mov     ax, 4F02h               ; fall back to VESA mode 101h
        mov     bx, 0101h
        int     10h
        cmp     ax, 004Fh
        je      .set
        stc
        ret
.set:
        mov     dx, 3C4h
        mov     ax, 1206h               ; SR6 = 12h: unlock extensions
        out     dx, ax
        mov     ax, 0F02h               ; SR2 = 0Fh: write all planes
        out     dx, ax
        mov     al, 07h                 ; read SR7 for the log
        out     dx, al
        inc     dx
        in      al, dx
        mov     [sr7], al
        mov     dx, 3CEh
        mov     al, 0Bh                 ; GRB: no dual bank, 4 KB granularity,
        out     dx, al                  ;      no extended write modes
        inc     dx
        in      al, dx
        mov     [grb], al
        and     al, 0C0h
        out     dx, al
        dec     dx
        mov     ax, 0001h               ; GR1 = 0: set/reset off
        out     dx, ax
        mov     ax, 0003h               ; GR3 = 0: no rotate, no logic op
        out     dx, ax
        mov     ax, 0FF08h              ; GR8 = FFh: all bits writable
        out     dx, ax
        mov     al, 05h                 ; GR5: write mode 0, read mode 0
        out     dx, al
        inc     dx
        in      al, dx
        and     al, 0F4h
        out     dx, al
        dec     dx
        mov     ax, 0009h               ; GR9 = 0: bank 0
        out     dx, ax
        clc
        ret

text_on:
        mov     ax, 0003h
        int     10h
        ret

; al = 64 KB bank number (0..15). 4 KB granularity: offset = bank * 16.
set_bank:
        push    ax
        push    dx
        mov     ah, al
        shl     ah, 4
        mov     al, 09h
        mov     dx, 3CEh
        out     dx, ax
        pop     dx
        pop     ax
        ret

; -----------------------------------------------------------------------------
; Run every test in the table once
run_tests:
        mov     si, tests
        mov     word [tidx], 0
.lp:    cmp     word [tidx], NTESTS
        jae     .done
        push    si
        call    do_test
        pop     si
        add     si, 7
        inc     word [tidx]
        cmp     byte [abort], 0
        je      .lp
.done:  cmp     byte [abort], 0
        jne     .r
        call    planar_test
.r:     ret

; si -> test entry (type byte, value dword, name word)
do_test:
        mov     al, [si]
        mov     [ttype], al
        mov     eax, [si+1]
        mov     [tval], eax
        mov     ax, [si+5]
        mov     [tname], ax
        ; seed for random tests: differs per pass and per test
        mov     eax, [pass]
        imul    eax, eax, 9E3779B1h
        movzx   edx, word [tidx]
        imul    edx, edx, 85EBCA6Bh
        xor     eax, edx
        or      eax, 1
        mov     [seed], eax
        ; generator used for the fill
        mov     al, [ttype]
        mov     byte [gtype], G_CONST
        cmp     al, T_CONST
        je      .g
        mov     byte [gtype], G_ADDR
        cmp     al, T_ADDR
        je      .g
        cmp     al, T_SCROLL
        je      .g
        mov     byte [gtype], G_RAND
.g:
        call    fill_all
        cmp     byte [abort], 0
        jne     .ret
        cmp     byte [ttype], T_HOLD
        jne     .nohold
        mov     cx, HOLDTICKS
        call    wait_ticks
        cmp     byte [abort], 0
        jne     .ret
.nohold:
        cmp     byte [ttype], T_SCROLL
        jne     .noscroll
        call    scroll_all
        cmp     byte [abort], 0
        jne     .ret
        mov     byte [gtype], G_SCRV
.noscroll:
        call    verify_all
.ret:   ret

; Expected value for linear address ebx -> eax (clobbers edx)
gen:
        mov     al, [gtype]
        cmp     al, G_CONST
        jne     .a
        mov     eax, [tval]
        ret
.a:     cmp     al, G_ADDR
        jne     .r
        mov     eax, ebx
        xor     eax, [tval]
        ret
.r:     cmp     al, G_RAND
        jne     .s
        mov     eax, [rstate]           ; xorshift32
        mov     edx, eax
        shl     edx, 13
        xor     eax, edx
        mov     edx, eax
        shr     edx, 17
        xor     eax, edx
        mov     edx, eax
        shl     edx, 5
        xor     eax, edx
        mov     [rstate], eax
        ret
.s:     ; after the scroll copy: each dword holds the address 256 bytes higher,
        ; except the last 256 bytes of each bank, which were not overwritten
        mov     eax, ebx
        cmp     bx, 0FF00h
        jae     .s1
        add     eax, 256
.s1:    ret

; Fill all banks with the current pattern
fill_all:
        push    es
        mov     ax, 0A000h
        mov     es, ax
        mov     eax, [seed]
        mov     [rstate], eax
        xor     ebx, ebx
        mov     byte [bank], 0
.bk:    mov     al, [bank]
        call    set_bank
        xor     di, di
.lp:    call    gen
        mov     [es:di], eax
        add     ebx, 4
        add     di, 4
        jnz     .lp
        call    check_key
        cmp     byte [abort], 0
        jne     .done
        inc     byte [bank]
        cmp     byte [bank], BANKS
        jb      .bk
.done:  pop     es
        ret

; Read every dword back and compare
verify_all:
        push    es
        mov     ax, 0A000h
        mov     es, ax
        mov     eax, [seed]
        mov     [rstate], eax
        xor     ebx, ebx
        mov     byte [bank], 0
.bk:    mov     al, [bank]
        call    set_bank
        xor     di, di
.lp:    call    gen
        mov     edx, [es:di]
        cmp     edx, eax
        jne     .err
.cont:  add     ebx, 4
        add     di, 4
        jnz     .lp
        call    check_key
        cmp     byte [abort], 0
        jne     .done
        inc     byte [bank]
        cmp     byte [bank], BANKS
        jb      .bk
.done:  pop     es
        ret
.err:   call    record_error
        jmp     .cont

; Copy each bank 256 bytes down inside itself, like a screen scroll
; (a read and a write for every dword)
scroll_all:
        push    es
        cld
        mov     byte [bank], 0
.bk:    mov     al, [bank]
        call    set_bank
        push    ds
        mov     ax, 0A000h
        mov     ds, ax
        mov     es, ax
        mov     si, 256
        xor     di, di
        mov     cx, (65536 - 256) / 4
        rep     movsd
        pop     ds
        call    check_key
        cmp     byte [abort], 0
        jne     .done
        inc     byte [bank]
        cmp     byte [bank], BANKS
        jb      .bk
.done:  pop     es
        ret

; -----------------------------------------------------------------------------
; Called on a mismatch: eax = expected, edx = read, ebx = linear address,
; es:di = location. Reads the location a second time and updates counters.
record_error:
        pushad
        mov     ecx, [es:di]            ; second read
        mov     [r2], ecx
        mov     [rexp], eax
        mov     [rgot], edx
        mov     [raddr], ebx
        ; type of error
        xor     si, si                  ; 0 = read glitch (second read correct)
        cmp     ecx, eax
        je      .cat
        mov     si, 4                   ; 1 = repeatable (second read same as first)
        cmp     ecx, edx
        je      .cat
        mov     si, 8                   ; 2 = unstable (second read different again)
.cat:   inc     dword [cat_tot+si]
        mov     [rcat], si
        inc     dword [err_pass]
        cmp     byte [ttype], T_CONST
        jne     .var
        inc     dword [err_fixed]
        jmp     .kind
.var:   inc     dword [err_var]
.kind:  movzx   esi, word [tidx]
        inc     dword [tst_pass+esi*4]
        inc     dword [tst_tot+esi*4]
        ; 64 KB block
        mov     esi, ebx
        shr     esi, 16
        and     esi, 0Fh
        inc     dword [blk_tot+esi*4]
        ; data lines
        mov     esi, [rgot]
        xor     esi, [rexp]             ; bits that differ
        mov     ebp, [rexp]
        xor     ecx, ecx
.bit:   bt      esi, ecx
        jnc     .nb
        inc     dword [md_pass+ecx*4]
        inc     dword [md_tot+ecx*4]
        bt      ebp, ecx
        jnc     .hi
        inc     dword [md_lo+ecx*4]     ; wrote 1, read 0
        jmp     .nb
.hi:    inc     dword [md_hi+ecx*4]     ; wrote 0, read 1
.nb:    inc     ecx
        cmp     ecx, 32
        jb      .bit
        ; address lines: only in the plain Address test, where every dword
        ; holds its own address. A value that is another valid address
        ; means the read came from the wrong place.
        cmp     byte [gtype], G_ADDR
        jne     .noaddr
        cmp     dword [tval], 0
        jne     .noaddr
        cmp     word [rcat], 4          ; repeatable errors only
        jne     .noaddr
        mov     eax, [rgot]
        test    eax, 3
        jnz     .noaddr
        cmp     eax, BANKS * 65536
        jae     .noaddr
        xor     eax, [raddr]
        mov     ecx, 2
.ab:    bt      eax, ecx
        jnc     .anb
        inc     dword [addr_hist+ecx*4]
.anb:   inc     ecx
        cmp     ecx, 20
        jb      .ab
.noaddr:
        ; keep the first few errors of this pass
        movzx   esi, byte [nerr]
        cmp     si, MAXERR
        jae     .done
        imul    si, si, ERRSZ
        add     si, errlist
        mov     eax, [raddr]
        mov     [si], eax
        mov     eax, [rexp]
        mov     [si+4], eax
        mov     eax, [rgot]
        mov     [si+8], eax
        mov     eax, [r2]
        mov     [si+12], eax
        mov     ax, [tname]
        mov     [si+16], ax
        mov     byte [si+18], 8
        inc     byte [nerr]
.done:  popad
        ret

clear_pass:
        mov     di, md_pass
        mov     cx, pass_clear_end - md_pass
        xor     al, al
        rep     stosb
        mov     dword [err_pass], 0
        mov     byte [nerr], 0
        ret

accumulate:
        mov     eax, [err_pass]
        add     [err_tot], eax
        test    eax, eax
        jz      .z
        inc     dword [pass_bad]
.z:     ret

; -----------------------------------------------------------------------------
; Keyboard: Esc sets the abort flag
check_key:
        push    ax
        mov     ah, 01h
        int     16h
        jz      .none
        mov     ah, 00h
        int     16h
        cmp     al, 1Bh
        jne     .none
        mov     byte [abort], 1
.none:  pop     ax
        ret

; BIOS tick counter -> eax
get_ticks:
        push    es
        xor     ax, ax
        mov     es, ax
        mov     eax, [es:046Ch]
        pop     es
        ret

; wait cx ticks, Esc aborts
wait_ticks:
        push    ebx
        movzx   ebx, cx
        call    get_ticks
        mov     [tw0], eax
.lp:    call    check_key
        cmp     byte [abort], 0
        jne     .done
        call    get_ticks
        sub     eax, [tw0]
        cmp     eax, ebx
        jb      .lp
.done:  pop     ebx
        ret

; Countdown on row 24: Enter = go now, Space = pause, Esc = quit
countdown:
        mov     byte [cd_secs], CDSECS
.sec:   call    buf_reset
        mov     si, [cd_prefix]
        call    buf_str
        xor     eax, eax
        mov     al, [cd_secs]
        mov     cl, 0
        call    buf_dec
        mov     si, s_cdkeys
        call    buf_str
        mov     dh, 24
        call    out_line
        call    get_ticks
        mov     [tw0], eax
.wait:  mov     ah, 01h
        int     16h
        jz      .nokey
        mov     ah, 00h
        int     16h
        cmp     al, 1Bh
        je      .esc
        cmp     al, 0Dh
        je      .go
        cmp     al, ' '
        je      .pause
        or      al, 20h
        cmp     al, 'd'
        je      .details
.nokey: call    get_ticks
        sub     eax, [tw0]
        cmp     eax, 18
        jb      .wait
        dec     byte [cd_secs]
        jnz     .sec
.go:    ret
.esc:   mov     byte [abort], 1
        ret
.details:
        call    text_on
        call    show_details
        mov     ah, 00h
        int     16h
        cmp     al, 1Bh
        je      .esc
        call    text_on
        call    show_report
        jmp     countdown
.pause: call    buf_reset
        mov     si, s_paused
        call    buf_str
        mov     dh, 24
        call    out_line
        mov     ah, 00h
        int     16h
        cmp     al, 1Bh
        je      .esc
        ret

; -----------------------------------------------------------------------------
; Elapsed time hh:mm:ss -> line buffer
buf_elapsed:
        call    get_ticks
        sub     eax, [t_start]
        jnc     .pos
        add     eax, 1800B0h            ; midnight roll-over
.pos:   mov     ecx, 10
        mul     ecx
        mov     ecx, 182
        div     ecx                     ; eax = seconds
        xor     edx, edx
        mov     ecx, 3600
        div     ecx                     ; eax = hours, edx = rest
        push    edx
        mov     byte [padc], '0'
        mov     cl, 2
        call    buf_dec
        mov     al, ':'
        call    buf_char
        pop     eax
        xor     edx, edx
        mov     ecx, 60
        div     ecx
        push    edx
        mov     cl, 2
        call    buf_dec
        mov     al, ':'
        call    buf_char
        pop     eax
        mov     cl, 2
        call    buf_dec
        mov     byte [padc], ' '
        ret

; -----------------------------------------------------------------------------
; Report screen
show_report:
        ; row 0: title, chip, pass, time
        call    buf_reset
        mov     si, s_title
        call    buf_str
        mov     si, s_sep
        call    buf_str
        call    buf_chipname
        mov     si, s_pass
        call    buf_str
        mov     eax, [pass]
        mov     cl, 0
        call    buf_dec
        mov     si, s_sep
        call    buf_str
        call    buf_elapsed
        mov     dh, 0
        call    out_line

        ; row 1: error totals
        call    buf_reset
        mov     si, s_thispass
        call    buf_str
        mov     eax, [err_pass]
        mov     cl, 0
        call    buf_dec
        mov     si, s_errs
        call    buf_str
        mov     si, s_allpass
        call    buf_str
        mov     eax, [err_tot]
        mov     cl, 0
        call    buf_dec
        mov     si, s_errs_in
        call    buf_str
        mov     eax, [pass_bad]
        mov     cl, 0
        call    buf_dec
        mov     si, s_of
        call    buf_str
        mov     eax, [pass]
        mov     cl, 0
        call    buf_dec
        mov     si, s_passes
        call    buf_str
        mov     dh, 1
        call    out_line

        ; rows 3-4: data line legend
        call    buf_reset
        mov     si, s_mdhead
        call    buf_str
        mov     dh, 3
        call    out_line
        call    buf_reset
        mov     si, s_lanes
        call    buf_str
        mov     dh, 4
        call    out_line

        ; rows 5-12: MD0-MD31, one column per byte lane
        mov     byte [row], 0
.mdrow: call    buf_reset
        mov     byte [col], 0
.mdcol: movzx   ax, byte [col]
        mov     bl, 20
        mul     bl
        call    buf_padto
        movzx   ecx, byte [col]
        shl     ecx, 3
        add     cl, [row]               ; ecx = data line number
        push    ecx
        mov     si, s_md
        call    buf_str
        mov     eax, ecx
        mov     cl, 0
        call    buf_dec
        movzx   ax, byte [col]
        mov     bl, 20
        mul     bl
        add     ax, 5
        call    buf_padto
        pop     ecx
        mov     eax, [md_tot+ecx*4]
        push    ecx
        mov     cl, 8
        call    buf_dec
        mov     al, ' '
        call    buf_char
        pop     ecx
        cmp     dword [md_tot+ecx*4], 0
        je      .flagdone
        mov     si, s_to0
        cmp     dword [md_hi+ecx*4], 0
        je      .flag
        mov     si, s_to1
        cmp     dword [md_lo+ecx*4], 0
        je      .flag
        mov     si, s_mix
.flag:  call    buf_str
.flagdone:
        inc     byte [col]
        cmp     byte [col], 4
        jb      .mdcol
        mov     dh, [row]
        add     dh, 5
        call    out_line
        inc     byte [row]
        cmp     byte [row], 8
        jb      .mdrow

        ; row 13: fixed patterns vs address/random tests vs planar
        call    buf_reset
        mov     si, s_kind1
        call    buf_str
        mov     eax, [err_fixed]
        mov     cl, 0
        call    buf_dec
        mov     si, s_kind2
        call    buf_str
        mov     eax, [err_var]
        mov     cl, 0
        call    buf_dec
        mov     si, s_kind3
        call    buf_str
        mov     eax, [err_planar]
        mov     cl, 0
        call    buf_dec
        mov     dh, 13
        call    out_line

        ; row 14: error types
        call    buf_reset
        mov     si, s_types1
        call    buf_str
        mov     eax, [cat_tot]
        mov     cl, 0
        call    buf_dec
        mov     si, s_types2
        call    buf_str
        mov     eax, [cat_tot+4]
        mov     cl, 0
        call    buf_dec
        mov     si, s_types3
        call    buf_str
        mov     eax, [cat_tot+8]
        mov     cl, 0
        call    buf_dec
        mov     dh, 14
        call    out_line

        ; rows 15-17: errors per 64 KB block
        call    buf_reset
        mov     si, s_blkhead
        call    buf_str
        mov     dh, 15
        call    out_line
        mov     byte [row], 0
.blkrow:
        call    buf_reset
        mov     si, s_blk0
        cmp     byte [row], 0
        je      .bh
        mov     si, s_blk1
.bh:    call    buf_str
        mov     byte [col], 0
.blkcol:
        movzx   ecx, byte [row]
        shl     ecx, 3
        add     cl, [col]
        mov     eax, [blk_tot+ecx*4]
        mov     cl, 8
        call    buf_dec
        inc     byte [col]
        cmp     byte [col], 8
        jb      .blkcol
        mov     dh, [row]
        add     dh, 16
        call    out_line
        inc     byte [row]
        cmp     byte [row], 2
        jb      .blkrow

        ; row 18: address lines
        call    buf_reset
        call    buf_addrhits
        mov     dh, 18
        call    out_line

        ; rows 19-22: first errors of this pass
        call    buf_reset
        mov     si, s_first
        cmp     byte [nerr], 0
        jne     .fh
        mov     si, s_noerr
.fh:    call    buf_str
        mov     dh, 19
        call    out_line
        xor     cx, cx
.fe:    cmp     cl, [nerr]
        jae     .fed
        cmp     cl, 3
        jae     .fed
        push    cx
        call    buf_reset
        mov     al, ' '
        call    buf_char
        call    buf_errentry
        pop     cx
        mov     dh, cl
        add     dh, 20
        push    cx
        call    out_line
        pop     cx
        inc     cx
        jmp     .fe
.fed:
        ; row 23: log status
        call    buf_reset
        mov     si, s_logok
        cmp     byte [logerr], 0
        je      .lg
        mov     si, s_logbad
.lg:    call    buf_str
        mov     dh, 23
        call    out_line
        ret

; address-line summary -> line buffer
buf_addrhits:
        mov     si, s_addrhead
        call    buf_str
        mov     byte [any], 0
        mov     ecx, 2
.lp:    cmp     dword [addr_hist+ecx*4], 0
        je      .nx
        mov     ax, [lbp]
        sub     ax, linebuf
        cmp     ax, 66
        jae     .more
        mov     byte [any], 1
        push    ecx
        mov     si, s_spA
        call    buf_str
        pop     ecx
        push    ecx
        mov     eax, ecx
        mov     cl, 0
        call    buf_dec
        mov     al, '='
        call    buf_char
        pop     ecx
        push    ecx
        mov     eax, [addr_hist+ecx*4]
        mov     cl, 0
        call    buf_dec
        pop     ecx
.nx:    inc     ecx
        cmp     ecx, 20
        jb      .lp
        cmp     byte [any], 0
        jne     .ret
        mov     si, s_addrnone
        call    buf_str
.ret:   ret
.more:  mov     si, s_more
        call    buf_str
        ret

; error entry cx -> line buffer
buf_errentry:
        mov     ax, ERRSZ
        mul     cx
        mov     bx, ax
        add     bx, errlist
        push    bx
        mov     si, [bx+16]
        call    buf_str
        mov     ax, [lbp]
        sub     ax, linebuf
        add     ax, 2
        cmp     ax, 12
        jae     .p
        mov     ax, 12
.p:     call    buf_padto
        pop     bx
        push    bx
        mov     si, s_eaddr
        call    buf_str
        pop     bx
        push    bx
        mov     eax, [bx]
        mov     cl, 5
        call    buf_hex
        mov     si, s_ewrote
        call    buf_str
        pop     bx
        push    bx
        mov     eax, [bx+4]
        mov     cl, [bx+18]
        call    buf_hex
        mov     si, s_eread
        call    buf_str
        pop     bx
        push    bx
        mov     eax, [bx+8]
        mov     cl, [bx+18]
        call    buf_hex
        mov     si, s_ereread
        call    buf_str
        pop     bx
        mov     eax, [bx+12]
        mov     cl, [bx+18]
        call    buf_hex
        ret

; -----------------------------------------------------------------------------
; Log file
log_header:
        call    buf_reset
        mov     si, s_lhead1
        call    buf_str
        mov     ah, 2Ah                 ; date
        int     21h
        push    dx
        movzx   eax, cx
        mov     cl, 0
        call    buf_dec
        mov     al, '-'
        call    buf_char
        mov     byte [padc], '0'
        pop     dx
        push    dx
        movzx   eax, dh
        mov     cl, 2
        call    buf_dec
        mov     al, '-'
        call    buf_char
        pop     dx
        movzx   eax, dl
        mov     cl, 2
        call    buf_dec
        mov     al, ' '
        call    buf_char
        mov     ah, 2Ch                 ; time
        int     21h
        push    dx
        push    cx
        movzx   eax, ch
        mov     cl, 2
        call    buf_dec
        mov     al, ':'
        call    buf_char
        pop     cx
        movzx   eax, cl
        mov     cl, 2
        call    buf_dec
        mov     al, ':'
        call    buf_char
        pop     dx
        movzx   eax, dh
        mov     cl, 2
        call    buf_dec
        mov     byte [padc], ' '
        mov     si, s_lhead2
        call    buf_str
        call    log_line
        call    buf_reset
        mov     si, s_lindent
        call    buf_str
        mov     si, s_chip
        call    buf_str
        call    buf_chipname
        call    log_line
        ret

log_pass:
        ; pass line
        call    buf_reset
        mov     si, s_lpass
        call    buf_str
        mov     eax, [pass]
        mov     cl, 0
        call    buf_dec
        mov     si, s_sep
        call    buf_str
        call    buf_elapsed
        mov     si, s_lerr
        call    buf_str
        mov     eax, [err_pass]
        mov     cl, 0
        call    buf_dec
        mov     si, s_ltot
        call    buf_str
        mov     eax, [err_tot]
        mov     cl, 0
        call    buf_dec
        mov     al, ')'
        call    buf_char
        cmp     byte [abort], 0
        je      .na
        mov     si, s_lstopped
        call    buf_str
.na:    call    log_line
        ; mode registers, first pass only
        cmp     dword [pass], 1
        jne     .nomode
        call    buf_reset
        mov     si, s_lmode
        call    buf_str
        xor     eax, eax
        mov     al, [sr7]
        mov     cl, 2
        call    buf_hex
        mov     si, s_lgrb
        call    buf_str
        xor     eax, eax
        mov     al, [grb]
        mov     cl, 2
        call    buf_hex
        call    log_line
.nomode:
        cmp     dword [err_pass], 0
        je      .ret
        ; data lines with errors in this pass
        call    buf_reset
        mov     si, s_llines
        call    buf_str
        xor     ecx, ecx
.ml:    cmp     dword [md_pass+ecx*4], 0
        je      .mn
        mov     ax, [lbp]
        sub     ax, linebuf
        cmp     ax, 62
        jb      .mfit
        push    ecx
        call    log_line
        call    buf_reset
        mov     si, s_lindent
        call    buf_str
        pop     ecx
.mfit:  push    ecx
        mov     si, s_spMD
        call    buf_str
        mov     eax, [esp]
        mov     cl, 0
        call    buf_dec
        mov     al, '='
        call    buf_char
        pop     ecx
        push    ecx
        mov     eax, [md_pass+ecx*4]
        mov     cl, 0
        call    buf_dec
        pop     ecx
.mn:    inc     ecx
        cmp     ecx, 32
        jb      .ml
        call    log_line
        call    log_pertest
        call    log_planar
        ; error details
        xor     cx, cx
.el:    cmp     cl, [nerr]
        jae     .ret
        push    cx
        call    buf_reset
        mov     si, s_lindent
        call    buf_str
        pop     cx
        push    cx
        call    buf_errentry
        call    log_line
        pop     cx
        inc     cx
        jmp     .el
.ret:   ret

log_footer:
        call    buf_reset
        mov     si, s_lfoot1
        call    buf_str
        mov     eax, [pass]
        mov     cl, 0
        call    buf_dec
        mov     si, s_lfoot2
        call    buf_str
        mov     eax, [err_tot]
        mov     cl, 0
        call    buf_dec
        mov     si, s_lfoot3
        call    buf_str
        call    log_line
        ret

; append line buffer + CR LF to the log buffer
log_line:
        push    si
        push    di
        push    cx
        mov     si, linebuf
        mov     di, [lgp]
        test    di, di
        jnz     .ok
        mov     di, logbuf
.ok:    mov     cx, logbuf + LOGMAX - 2
        cmp     di, cx
        jae     .skip
.cp:    cmp     si, [lbp]
        jae     .end
        cmp     di, cx
        jae     .end
        mov     al, [si]
        mov     [di], al
        inc     si
        inc     di
        jmp     .cp
.end:   mov     word [di], 0A0Dh
        add     di, 2
        mov     [lgp], di
.skip:  pop     cx
        pop     di
        pop     si
        ret

; write the log buffer to VRAMTEST.LOG (append) and empty it
log_flush:
        mov     cx, [lgp]
        test    cx, cx
        jz      .ret
        sub     cx, logbuf
        jz      .ret
        mov     [loglen], cx
        mov     dx, logname
        mov     ax, 3D01h               ; open for writing
        int     21h
        jnc     .open
        mov     dx, logname
        mov     ah, 3Ch                 ; create
        xor     cx, cx
        int     21h
        jc      .fail
.open:  mov     bx, ax
        mov     ax, 4202h               ; seek to end
        xor     cx, cx
        xor     dx, dx
        int     21h
        jc      .failc
        mov     ah, 40h
        mov     cx, [loglen]
        mov     dx, logbuf
        int     21h
        jc      .failc
        cmp     ax, [loglen]
        jne     .failc
        mov     ah, 3Eh
        int     21h
        mov     word [lgp], logbuf
.ret:   ret
.failc: mov     ah, 3Eh
        int     21h
.fail:  mov     byte [logerr], 1
        mov     word [lgp], logbuf
        ret

; -----------------------------------------------------------------------------
; Line buffer helpers
buf_reset:
        mov     word [lbp], linebuf
        ret

; al -> buffer
buf_char:
        push    bx
        mov     bx, [lbp]
        cmp     bx, linebuf + 79
        jae     .full
        mov     [bx], al
        inc     bx
        mov     [lbp], bx
.full:  pop     bx
        ret

; zero-terminated string at si -> buffer
buf_str:
        push    ax
.lp:    lodsb
        test    al, al
        jz      .done
        call    buf_char
        jmp     .lp
.done:  pop     ax
        ret

; pad with spaces up to column ax
buf_padto:
        push    bx
.lp:    mov     bx, [lbp]
        sub     bx, linebuf
        cmp     bx, ax
        jae     .done
        push    ax
        mov     al, ' '
        call    buf_char
        pop     ax
        cmp     word [lbp], linebuf + 79
        jae     .done
        jmp     .lp
.done:  pop     bx
        ret

; eax unsigned decimal, cl = minimum width (padded with [padc])
buf_dec:
        push    ebx
        push    edx
        push    si
        mov     si, decbuf + 11
        mov     byte [si], 0
        mov     ebx, 10
.lp:    xor     edx, edx
        div     ebx
        add     dl, '0'
        dec     si
        mov     [si], dl
        test    eax, eax
        jnz     .lp
        mov     ax, decbuf + 11
        sub     ax, si                  ; digits
        movzx   bx, cl
.pad:   cmp     ax, bx
        jae     .out
        push    ax
        mov     al, [padc]
        call    buf_char
        pop     ax
        inc     ax
        jmp     .pad
.out:   call    buf_str
        pop     si
        pop     edx
        pop     ebx
        ret

; eax as cl hex digits
buf_hex:
        push    edx
        push    bx
        push    cx
        mov     edx, eax
        mov     ch, 8
        sub     ch, cl
        shl     ch, 2
        mov     al, cl
        mov     cl, ch
        rol     edx, cl                 ; drop unused high digits
        mov     cl, al
.lp:    rol     edx, 4
        mov     bl, dl
        and     bx, 0Fh
        mov     al, [hexdig+bx]
        call    buf_char
        dec     cl
        jnz     .lp
        pop     cx
        pop     bx
        pop     edx
        ret

; print the line buffer on screen row dh (no scrolling)
out_line:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        mov     ah, 02h
        xor     bh, bh
        xor     dl, dl
        int     10h
        mov     si, linebuf
.lp:    cmp     si, [lbp]
        jae     .clr
        mov     al, [si]
        mov     ah, 0Eh
        xor     bh, bh
        mov     bl, 07h
        int     10h
        inc     si
        jmp     .lp
.clr:   ; clear the rest of the row (79 columns)
        mov     ax, [lbp]
        sub     ax, linebuf
        mov     cx, 79
        sub     cx, ax
        jbe     .done
        mov     ax, 0920h
        mov     bx, 0007h
        int     10h
.done:  pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; put the cursor at column 0 of row dh
park_cursor:
        mov     ah, 02h
        xor     bh, bh
        xor     dl, dl
        int     10h
        ret


; -----------------------------------------------------------------------------
; Planar split test, mode 12h (640x480x16), first 64 KB of each plane.
; Byte writes and reads, one plane at a time. Even CPU addresses travel on
; host data bus D0-7, odd addresses on D8-15, whatever the plane.
planar_test:
        mov     ax, 0012h
        int     10h
        mov     ah, 0Fh
        int     10h
        and     al, 7Fh
        cmp     al, 12h
        je      .ok
        mov     byte [planar_fail], 1
        ret
.ok:    mov     byte [planar_fail], 0
        mov     dx, 3C4h
        mov     ax, 1206h               ; unlock extensions
        out     dx, ax
        mov     dx, 3CEh
        mov     al, 0Bh                 ; GRB: no dual bank, no extended writes
        out     dx, al
        inc     dx
        in      al, dx
        and     al, 0C0h
        out     dx, al
        dec     dx
        mov     ax, 0001h               ; GR1 = 0: set/reset off
        out     dx, ax
        mov     ax, 0003h               ; GR3 = 0
        out     dx, ax
        mov     ax, 0FF08h              ; GR8 = FFh
        out     dx, ax
        mov     al, 05h                 ; GR5: write mode 0, read mode 0
        out     dx, al
        inc     dx
        in      al, dx
        and     al, 0F4h
        out     dx, al
        dec     dx
        mov     ax, 0009h               ; GR9 = 0
        out     dx, ax
        push    es
        mov     ax, 0A000h
        mov     es, ax
        mov     word [tname], 0
        mov     byte [ppat], 0
.pat:   mov     byte [pplane], 0
.fp:    call    pl_select_write
        call    pl_seed
        xor     di, di
.fl:    call    pgen
        mov     [es:di], al
        inc     di
        jnz     .fl
        inc     byte [pplane]
        cmp     byte [pplane], 4
        jb      .fp
        call    check_key
        cmp     byte [abort], 0
        jne     .done
        mov     byte [pplane], 0
.vp:    call    pl_select_read
        call    pl_seed
        xor     di, di
.vl:    call    pgen
        mov     ah, [es:di]
        cmp     ah, al
        jne     .err
.vc:    inc     di
        jnz     .vl
        inc     byte [pplane]
        cmp     byte [pplane], 4
        jb      .vp
        call    check_key
        cmp     byte [abort], 0
        jne     .done
        inc     byte [ppat]
        cmp     byte [ppat], NPPAT
        jb      .pat
.done:  pop     es
        ret
.err:   call    planar_error
        jmp     .vc

; SR2 map mask = this plane only
pl_select_write:
        push    cx
        mov     cl, [pplane]
        mov     ah, 1
        shl     ah, cl
        mov     al, 02h
        mov     dx, 3C4h
        out     dx, ax
        pop     cx
        ret

; GR4 read map select = this plane
pl_select_read:
        mov     ah, [pplane]
        mov     al, 04h
        mov     dx, 3CEh
        out     dx, ax
        ret

; seed per pass, pattern and plane
pl_seed:
        mov     eax, [pass]
        imul    eax, eax, 9E3779B1h
        movzx   edx, byte [ppat]
        imul    edx, edx, 85EBCA6Bh
        xor     eax, edx
        movzx   edx, byte [pplane]
        imul    edx, edx, 0C2B2AE35h
        xor     eax, edx
        or      eax, 1
        mov     [rstate], eax
        mov     al, [pplane]
        mov     ah, 3Bh
        mul     ah
        mov     [pmix], al
        ret

; byte pattern for address di -> al
;   0: 55h   1: AAh   2: address mix   3: inverted address mix   4: random
pgen:
        mov     dl, [ppat]
        cmp     dl, 0
        jne     .p1
        mov     al, 55h
        ret
.p1:    cmp     dl, 1
        jne     .p2
        mov     al, 0AAh
        ret
.p2:    cmp     dl, 4
        je      .rnd
        mov     ax, di
        xor     al, ah
        xor     al, [pmix]
        cmp     dl, 3
        jne     .r
        not     al
.r:     ret
.rnd:   push    edx
        mov     eax, [rstate]
        mov     edx, eax
        shl     edx, 13
        xor     eax, edx
        mov     edx, eax
        shr     edx, 17
        xor     eax, edx
        mov     edx, eax
        shl     edx, 5
        xor     eax, edx
        mov     [rstate], eax
        pop     edx
        ret

; mismatch in the planar test: al = expected, ah = read, es:di = location
planar_error:
        pushad
        mov     [pexp], al
        mov     [pgot], ah
        mov     bl, [es:di]             ; second read
        mov     [pre], bl
        inc     dword [err_pass]
        inc     dword [err_planar]
        movzx   esi, byte [pplane]
        shl     esi, 1
        mov     ax, di
        and     ax, 1
        add     si, ax                  ; plane * 2 + address parity
        inc     dword [perr_pass+esi*4]
        inc     dword [perr_tot+esi*4]
        movzx   esi, byte [nerr]
        cmp     si, MAXERR
        jae     .done
        imul    si, si, ERRSZ
        add     si, errlist
        movzx   eax, di
        mov     [si], eax
        movzx   eax, byte [pexp]
        mov     [si+4], eax
        movzx   eax, byte [pgot]
        mov     [si+8], eax
        movzx   eax, byte [pre]
        mov     [si+12], eax
        movzx   bx, byte [pplane]
        shl     bx, 1
        mov     ax, [pnames+bx]
        mov     [si+16], ax
        mov     byte [si+18], 2
        inc     byte [nerr]
.done:  popad
        ret

; -----------------------------------------------------------------------------
; Details page: errors per test and the planar split table
show_details:
        call    buf_reset
        mov     si, s_title
        call    buf_str
        mov     si, s_details
        call    buf_str
        mov     si, s_pass
        call    buf_str
        mov     eax, [pass]
        mov     cl, 0
        call    buf_dec
        mov     dh, 0
        call    out_line

        call    buf_reset
        mov     si, s_pertest
        call    buf_str
        mov     dh, 1
        call    out_line

        mov     byte [row], 0
.trow:  call    buf_reset
        movzx   bx, byte [row]
        call    buf_testcell
        mov     ax, 40
        call    buf_padto
        movzx   bx, byte [row]
        add     bx, 15
        call    buf_testcell
        mov     dh, [row]
        add     dh, 2
        call    out_line
        inc     byte [row]
        cmp     byte [row], 15
        jb      .trow

        call    buf_reset
        mov     si, s_plhead
        call    buf_str
        mov     dh, 17
        call    out_line
        call    buf_reset
        mov     si, s_plcols
        call    buf_str
        mov     dh, 18
        call    out_line

        cmp     byte [planar_fail], 0
        je      .pl
        call    buf_reset
        mov     si, s_plfail
        call    buf_str
        mov     dh, 19
        call    out_line
        jmp     .hint
.pl:    mov     byte [row], 0
.prow:  call    buf_reset
        movzx   bx, byte [row]
        shl     bx, 1
        mov     si, [pl_labels+bx]
        call    buf_str
        mov     ax, 20
        call    buf_padto
        movzx   ecx, byte [row]
        shl     ecx, 1
        mov     eax, [perr_tot+ecx*4]
        push    ecx
        mov     cl, 12
        call    buf_dec
        pop     ecx
        mov     eax, [perr_tot+ecx*4+4]
        mov     cl, 18
        call    buf_dec
        mov     dh, [row]
        add     dh, 19
        call    out_line
        inc     byte [row]
        cmp     byte [row], 4
        jb      .prow
.hint:  call    buf_reset
        mov     si, s_plhint
        call    buf_str
        mov     dh, 23
        call    out_line
        call    buf_reset
        mov     si, s_detkeys
        call    buf_str
        mov     dh, 24
        call    out_line
        ret

; one cell of the per-test list: bx = index (0..29). Index NTESTS = planar.
buf_testcell:
        cmp     bx, NTESTS
        ja      .ret
        je      .planar
        push    bx
        mov     ax, 7
        mul     bx
        mov     bx, ax
        mov     si, [tests+bx+5]
        mov     ax, [lbp]
        sub     ax, linebuf
        push    ax
        call    buf_str
        pop     ax
        add     ax, 11
        call    buf_padto
        pop     bx
        movzx   ebx, bx
        mov     eax, [tst_tot+ebx*4]
        mov     cl, 10
        call    buf_dec
.ret:   ret
.planar:
        mov     ax, [lbp]
        sub     ax, linebuf
        push    ax
        mov     si, s_plshort
        call    buf_str
        pop     ax
        add     ax, 13
        call    buf_padto
        mov     eax, [err_planar]
        mov     cl, 8
        call    buf_dec
        ret

; log: tests with errors in this pass
log_pertest:
        call    buf_reset
        mov     si, s_ltests
        call    buf_str
        xor     bx, bx
.lp:    cmp     bx, NTESTS
        jae     .end
        movzx   ebx, bx
        cmp     dword [tst_pass+ebx*4], 0
        je      .nx
        mov     ax, [lbp]
        sub     ax, linebuf
        cmp     ax, 56
        jb      .fit
        push    bx
        call    log_line
        call    buf_reset
        mov     si, s_lindent
        call    buf_str
        pop     bx
.fit:   push    bx
        mov     al, ' '
        call    buf_char
        mov     ax, 7
        mul     bx
        mov     bx, ax
        mov     si, [tests+bx+5]
        call    buf_str
        mov     al, '='
        call    buf_char
        pop     bx
        push    bx
        movzx   ebx, bx
        mov     eax, [tst_pass+ebx*4]
        mov     cl, 0
        call    buf_dec
        pop     bx
.nx:    inc     bx
        jmp     .lp
.end:   call    log_line
        ret

; log: planar split counts for this pass
log_planar:
        call    buf_reset
        mov     si, s_lplanar
        call    buf_str
        cmp     byte [planar_fail], 0
        je      .ok
        mov     si, s_lplfail
        call    buf_str
        call    log_line
        ret
.ok:    xor     ecx, ecx
.lp:    mov     si, s_lP
        call    buf_str
        mov     eax, ecx
        shr     eax, 1
        push    ecx
        mov     cl, 0
        call    buf_dec
        mov     al, ' '
        call    buf_char
        pop     ecx
        mov     eax, [perr_pass+ecx*4]
        push    ecx
        mov     cl, 0
        call    buf_dec
        mov     al, '/'
        call    buf_char
        pop     ecx
        mov     eax, [perr_pass+ecx*4+4]
        push    ecx
        mov     cl, 0
        call    buf_dec
        pop     ecx
        add     ecx, 2
        cmp     ecx, 8
        jb      .lp
        call    log_line
        ret

pnames      dw pn0, pn1, pn2, pn3
pn0         db "Planar P0",0
pn1         db "Planar P1",0
pn2         db "Planar P2",0
pn3         db "Planar P3",0
pl_labels   dw pl0, pl1, pl2, pl3
pl0         db "Plane 0 (MD0-7)",0
pl1         db "Plane 1 (MD8-15)",0
pl2         db "Plane 2 (MD16-23)",0
pl3         db "Plane 3 (MD24-31)",0
s_details   db "  Details",0
s_pertest   db "Errors per test, all passes (32-bit reads in 256-colour mode):",0
s_plshort   db "Planar split",0
s_plhead    db "Planar split test, all passes (byte reads, 16-colour mode):",0
s_plcols    db "                       even address (D0-7)   odd address (D8-15)",0
s_plfail    db "Could not set mode 12h, so the planar test was not run.",0
s_plhint    db "Odd column bad in every plane: host bus D8-15. Planes 1+3 bad: video RAM.",0
s_detkeys   db "Details. Press any key to go back, Esc to quit.",0
s_ltests    db "  Tests:",0
s_lplanar   db "  Planar split (even/odd address):",0
s_lplfail   db " not run, mode 12h failed",0
s_lP        db "  P",0

; -----------------------------------------------------------------------------
; Test table: type, value, name
%macro TST 3
        db      %1
        dd      %2
        dw      %3
%endmacro

tests:
        TST     T_ADDR,   00000000h, n_addr
        TST     T_ADDR,   0FFFFFFFFh, n_addri
        TST     T_SCROLL, 00000000h, n_scroll
        TST     T_CONST,  00000000h, n_c00
        TST     T_CONST,  0FFFFFFFFh, n_cff
        TST     T_CONST,  55555555h, n_c55
        TST     T_CONST,  0AAAAAAAAh, n_caa
        TST     T_CONST,  33333333h, n_c33
        TST     T_CONST,  0CCCCCCCCh, n_ccc
        TST     T_CONST,  0F0F0F0Fh, n_c0f
        TST     T_CONST,  0F0F0F0F0h, n_cf0
%assign b 0
%rep 8
        TST     T_CONST,  (1 << b) * 01010101h, n_w1_ %+ b
%assign b b+1
%endrep
%assign b 0
%rep 8
        TST     T_CONST,  ((~(1 << b)) & 0FFh) * 01010101h, n_w0_ %+ b
%assign b b+1
%endrep
        TST     T_RAND,   0, n_rand
        TST     T_HOLD,   0, n_hold
tests_end:
NTESTS  equ     (tests_end - tests) / 7

; -----------------------------------------------------------------------------
; Strings
n_addr      db "Address",0
n_addri     db "Addr inv",0
n_scroll    db "Scroll",0
n_c00       db "All 0s",0
n_cff       db "All 1s",0
n_c55       db "Check 55",0
n_caa       db "Check AA",0
n_c33       db "Check 33",0
n_ccc       db "Check CC",0
n_c0f       db "Check 0F",0
n_cf0       db "Check F0",0
%assign b 0
%rep 8
n_w1_ %+ b  db "Walk1 b", '0'+b, 0
%assign b b+1
%endrep
%assign b 0
%rep 8
n_w0_ %+ b  db "Walk0 b", '0'+b, 0
%assign b b+1
%endrep
n_rand      db "Random",0
n_hold      db "Hold 3s",0

s_title     db "Tony359's VRAM TEST for GD542x v0.2",0
s_sep       db "  ",0
s_chip      db "Graphics chip: ",0
s_idopen    db " (ID ",0
s_unknown   db "unknown chip",0
s_nochip    db "No Cirrus Logic CL-GD542x found (chip ID ",0
s_nochip2   db ").",0
s_nochip3   db "Use VRAMTEST /F to run anyway.",0
s_nomode    db "Could not set video mode 5Fh (640x480x256). Test not run.",0

intro_lines dw s_i1, s_i2, s_i3, s_i4, s_i5, s_i6, s_i7, s_i8, s_i9, 0
s_i1        db "Tests all 1 MB of video memory in a loop.",0
s_i2        db "During a pass the screen shows test patterns. That is normal.",0
s_i3        db "Each pass runs 29 tests in 256-colour mode, then a planar split test in",0
s_i4        db "16-colour mode that tells host bus faults from video memory faults.",0
s_i5        db "Errors are counted per memory data line MD0-MD31 of the graphics chip.",0
s_i6        db "After each pass a report shows for 10 s. D shows a details page.",0
s_i7        db "Results are added to VRAMTEST.LOG in the current directory after each pass.",0
s_i8        db " ",0
s_i9        db "Esc stops the test at any time (it may take a second to respond).",0

s_start     db "Starting in ",0
s_next      db "Next pass in ",0
s_cdkeys    db " s.  Enter = start now  D = details  Space = pause  Esc = quit",0
s_pressenter db "Press Enter to start the test, Esc to quit.",0
s_paused    db "Paused. Press any key to continue, Esc to quit.",0
s_stopped   db "Stopped. Results are in VRAMTEST.LOG.",0

s_pass      db "  Pass ",0
s_thispass  db "This pass: ",0
s_errs      db " errors.   ",0
s_allpass   db "All passes: ",0
s_errs_in   db " errors, ",0
s_of        db " of ",0
s_passes    db " passes failed.",0
s_mdhead    db "Bit errors per data line, all passes  (->0 read 0 not 1, ->1 read 1 not 0)",0
s_lanes     db "Lane 0: MD0-7       Lane 1: MD8-15      Lane 2: MD16-23     Lane 3: MD24-31",0
s_md        db "MD",0
s_to0       db "->0",0
s_to1       db "->1",0
s_mix       db "mix",0
s_kind1     db "Fixed patterns ",0
s_kind2     db "   Addr/random/scroll ",0
s_kind3     db "   Planar split ",0
s_types1    db "Types: read glitch ",0
s_types2    db "   repeatable ",0
s_types3    db "   unstable ",0
s_blkhead   db "Errors per 64 KB block, all passes:",0
s_blk0      db "  0-7 ",0
s_blk1      db " 8-15 ",0
s_addrhead  db "Address test, wrong address bits:",0
s_addrnone  db " none",0
s_spA       db " A",0
s_more      db " ...",0
s_first     db "First errors this pass:",0
s_noerr     db "No errors this pass.",0
s_eaddr     db "addr ",0
s_ewrote    db "  wrote ",0
s_eread     db "  read ",0
s_ereread   db "  reread ",0
s_logok     db "Log: VRAMTEST.LOG",0
s_logbad    db "Log: could not write VRAMTEST.LOG",0

s_lhead1    db "=== Tony359's VRAM TEST for GD542x v0.2 started ",0
s_lhead2    db " ===",0
s_lpass     db "Pass ",0
s_lerr      db "  errors ",0
s_ltot      db "  (total ",0
s_lstopped  db "  stopped by Esc",0
s_lmode     db "  Mode 5Fh registers: SR7=",0
s_lgrb      db " GRB=",0
s_llines    db "  Data lines:",0
s_lindent   db "    ",0
s_spMD      db " MD",0
s_lfoot1    db "=== Stopped after ",0
s_lfoot2    db " passes, total errors ",0
s_lfoot3    db " ===",0

chipnames   db 88h
            dw cn_5420
            db 8Ch
            dw cn_5422
            db 90h
            dw cn_5426
            db 94h
            dw cn_5424
            db 98h
            dw cn_5428
            db 9Ch
            dw cn_5429
            db 0
cn_5420     db "CL-GD5420",0
cn_5422     db "CL-GD5422",0
cn_5424     db "CL-GD5424",0
cn_5426     db "CL-GD5426",0
cn_5428     db "CL-GD5428",0
cn_5429     db "CL-GD5429",0

hexdig      db "0123456789ABCDEF"
logname     db "VRAMTEST.LOG",0

; -----------------------------------------------------------------------------
        section .bss align=4
bss_start:
md_pass     resd 32
tst_pass    resd NTESTS
perr_pass   resd 8
pass_clear_end:
tst_tot     resd NTESTS
perr_tot    resd 8
err_planar  resd 1
md_tot      resd 32
md_lo       resd 32
md_hi       resd 32
blk_tot     resd 16
cat_tot     resd 3
addr_hist   resd 20
pass        resd 1
pass_bad    resd 1
err_pass    resd 1
err_tot     resd 1
err_fixed   resd 1
err_var     resd 1
t_start     resd 1
tw0         resd 1
tval        resd 1
seed        resd 1
rstate      resd 1
r2          resd 1
rexp        resd 1
rgot        resd 1
raddr       resd 1
tidx        resw 1
rcat        resw 1
tname       resw 1
lbp         resw 1
lgp         resw 1
loglen      resw 1
cd_prefix   resw 1
chipid      resb 1
force       resb 1
abort       resb 1
ttype       resb 1
gtype       resb 1
bank        resb 1
nerr        resb 1
row         resb 1
col         resb 1
any         resb 1
cd_secs     resb 1
padc        resb 1
logerr      resb 1
sr7         resb 1
grb         resb 1
ppat        resb 1
pplane      resb 1
pmix        resb 1
pexp        resb 1
pgot        resb 1
pre         resb 1
planar_fail resb 1
            alignb 4
errlist     resb MAXERR * ERRSZ
decbuf      resb 12
linebuf     resb 84
logbuf      resb LOGMAX
bss_end:
