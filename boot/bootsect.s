	.code16 # 强制16位实模式
# rewrite with AT&T syntax by falcon <wuzhangjin@gmail.com> at 081012
#
# SYS_SIZE is the number of clicks (16 bytes) to be loaded.
# 0x3000 is 0x30000 bytes = 196kB, more than enough for current
# versions of linux
#
	.equ SYSSIZE, 0x3000
#
#	bootsect.s		(C) 1991 Linus Torvalds
#
# bootsect.s is loaded at 0x7c00 by the bios-startup routines, and moves
# iself out of the way to address 0x90000, and jumps there.
#
# It then loads 'setup' directly after itself (0x90200), and the system
# at 0x10000, using BIOS interrupts. 
#
# NOTE! currently system is at most 8*65536 bytes long. This should be no
# problem, even in the future. I want to keep it simple. This 512 kB
# kernel size should be enough, especially as this doesn't contain the
# buffer cache as in minix
#
# The loader has been made as simple as possible, and continuos
# read errors will result in a unbreakable loop. Reboot by hand. It
# loads pretty fast by getting whole sectors at a time whenever possible.

	.global _start, begtext, begdata, begbss, endtext, enddata, endbss
	.text
	begtext:
	.data
	begdata:
	.bss
	begbss:
	.text

	.equ SETUPLEN, 4		# nr of setup-sectors
	.equ BOOTSEG, 0x07c0		# original address of boot-sector
	.equ INITSEG, 0x9000		# we move boot here - out of the way
	.equ SETUPSEG, 0x9020		# setup starts here
	.equ SYSSEG, 0x1000		# system loaded at 0x10000 (65536).
	.equ ENDSEG, SYSSEG + SYSSIZE	# where to stop loading

# ROOT_DEV:	0x000 - same type of floppy as boot.
#		0x301 - first partition on first drive etc
#
##和源码不同，源码中是0x306 第2块硬盘的第一个分区
#
	.equ ROOT_DEV, 0x301 # 初始设置ROOT_DEV等于0x301，写入bootsect二进制后，可在build.sh阶段修改该值，实现构建时配置根设备的灵活性
	ljmp    $BOOTSEG, $_start # 使用ljmp指令进行段间跳转，刷新cs寄存器，方便后续使用
_start:
	mov	$BOOTSEG, %ax	#将ds段寄存器设置为0x7C0
	mov	%ax, %ds
	mov	$INITSEG, %ax	#将es段寄存器设置为0x900
	mov	%ax, %es
	mov	$256, %cx		#设置移动计数值256字
	sub	%si, %si		#源地址	ds:si = 0x07C0:0x0000
	sub	%di, %di		#目标地址 es:si = 0x9000:0x0000
	rep					#重复执行并递减cx的值
	movsw				#从内存[si]处移动cx个字到[di]处
	ljmp	$INITSEG, $go	#段间跳转，这里INITSEG指出跳转到的段地址，解释了cs的值为0x9000
go:	mov	%cs, %ax		#将ds，es，ss都设置成移动后代码所在的段处(0x9000)
	mov	%ax, %ds
	mov	%ax, %es
# put stack at 0x9ff00.
	mov	%ax, %ss
	mov	$0xFF00, %sp    # arbitrary value >>512 (x86栈固定向下增长，为了保证不与0x90000起始的bootsect/setup冲突，选择一个较远的值)

# load the setup-sectors directly after the bootblock.
# Note that 'es' is already set up.
# 磁盘数据寻址有CHS和LBA两种，当前启动阶段只能使用CHS:柱面、磁头、扇区三元组
#
##ah=0x02 读磁盘扇区到内存	al＝需要独出的扇区数量
##ch=磁道(柱面)号的低八位   cl＝开始扇区(位0-5),磁道号高2位(位6－7)
##dh=磁头号					dl=驱动器号(硬盘则7要置位)
##es:bx ->指向数据缓冲区；如果出错则CF标志置位,ah中是出错码
#
load_setup:
	mov	$0x0000, %dx		# drive 0(表示软盘), head 0
	mov	$0x0002, %cx		# sector 2(扇区从1开始计数，柱面、磁头等则从0开始计数), track 0
	mov	$0x0200, %bx		# address = 512, in INITSEG
	.equ    AX, 0x0200+SETUPLEN # AH=0x02表示读取磁盘扇区到内存，AL=需要读取的扇区数量
	mov     $AX, %ax		# service 2, nr of sectors
	int	$0x13			# read it
	jnc	ok_load_setup		# ok - continue
	mov	$0x0000, %dx        # (DL=00H~7FH表示软盘)
	mov	$0x0000, %ax		# reset the diskette(AH=00H 磁盘系统复位功能)
	int	$0x13
	jmp	load_setup

ok_load_setup:

# Get disk drive parameters, specifically nr of sectors/track
# AH=8时 BIOS INT 0x13能返回很多信息，但当前只关注扇区数(存储在sectors变量中)
	mov	$0x00, %dl # DL=00H~7FH表示软盘
	mov	$0x0800, %ax		# AH=8 is get drive parameters
	int	$0x13 # 出口参数:CF=1操作失败 AH=状态代码 BL=01H(360K软盘)/02H(1.2m软盘)/03H(720K软盘)/04H(1.44M软盘) CH=柱面数低8位 CL[7:6]=柱面数高2位 CL[5:0]=每磁道扇区数 DH=磁头数 DL=驱动器数 ES:DI=磁盘驱动器参数表地址
	mov	$0x00, %ch
	#seg cs # 原来代码通过seg cs强制使用cs代码段，这里注释掉，%cs:sectors显式指定段
	mov	%cx, %cs:sectors+0	# %cs means sectors is in %cs (sectors定义在后面，用来存储扇区数————CH前面赋值为00，因此CX存储扇区数)
	mov	$INITSEG, %ax
	mov	%ax, %es # 由于前面ES:DI=磁盘驱动器参数表地址，修改了ES，因此需要改回

# Print some inane message

	mov	$0x03, %ah		# read cursor pos
	xor	%bh, %bh
	int	$0x10
	
	mov	$30, %cx
	mov	$0x0007, %bx		# page 0, attribute 7 (normal)
	#lea	msg1, %bp # 该行被注释掉，功能与下面一行等价
	mov     $msg1, %bp # ES:BP指向显示字符串的地址
	mov	$0x1301, %ax		# write string, move cursor
	int	$0x10

# ok, we've written the message, now
# we want to load the system (at 0x10000)

	mov	$SYSSEG, %ax
	mov	%ax, %es		# segment of 0x010000
	call	read_it
	call	kill_motor

# After that we check which root-device to use. If the device is
# defined (#= 0), nothing is done and the given device is used.
# Otherwise, either /dev/PS0 (2,28) or /dev/at0 (2,8), depending
# on the number of sectors that the BIOS reports currently.

	#seg cs
	mov	%cs:root_dev+0, %ax
	cmp	$0, %ax
	jne	root_defined
	#seg cs
	mov	%cs:sectors+0, %bx
	mov	$0x0208, %ax		# /dev/ps0 - 1.2Mb
	cmp	$15, %bx
	je	root_defined
	mov	$0x021c, %ax		# /dev/PS0 - 1.44Mb
	cmp	$18, %bx
	je	root_defined
undef_root:
	jmp undef_root
root_defined:
	#seg cs
	mov	%ax, %cs:root_dev+0

# after that (everyting loaded), we jump to
# the setup-routine loaded directly after
# the bootblock:

	ljmp	$SETUPSEG, $0

# This routine loads the system at address 0x10000, making sure
# no 64kB boundaries are crossed. We try to load it as fast as
# possible, loading whole tracks whenever we can.
#
# in:	es - starting address segment (normally 0x1000)
#
sread:	.word 1+ SETUPLEN	# sectors read of current track
head:	.word 0			# current head
track:	.word 0			# current track

read_it:
	mov	%es, %ax # 0x1000
	test	$0x0fff, %ax
die:	jne 	die			# es must be at 64kB boundary
	xor 	%bx, %bx		# bx is starting address within segment
rp_read:
	mov 	%es, %ax
 	cmp 	$ENDSEG, %ax		# have we loaded all yet?
	jb	ok1_read # 如果ax(初始0x1000，每次加0x1000)小于(0x1000+0x3000)，则跳到ok1_read继续加载，否则返回
	ret
ok1_read:
	#seg cs # 将seg cs注释掉，后面显式的指定段，如mov %cs:sectors+0, %ax
	mov	%cs:sectors+0, %ax
	sub	sread, %ax # sread=5,sectors=每磁道扇区数,sub后ax存储磁道剩余扇区数
	mov	%ax, %cx
	shl	$9, %cx # 剩余扇区数*512=剩余字节数
	add	%bx, %cx
	jnc 	ok2_read # 没进位说明剩余拷贝数不超过64KB(16位实模式下加法运算也是16位的)，可以安全拷贝(段长度限定64KB)，跳转到ok2_read
	je 	ok2_read # 如果运算结果为0(说明刚好在64KB边界上, shl $9 %cx可能触发)，则跳转到ok2_read
	xor 	%ax, %ax
	sub 	%bx, %ax
	shr 	$9, %ax
ok2_read:
	call 	read_track # 读磁道上的扇区
	mov 	%ax, %cx # ax存储read_track中int $0x13出参，表示read_trace成功读取的扇区数，cx存储之前已读取扇区数
	add 	sread, %ax
	#seg cs
	cmp 	%cs:sectors+0, %ax # 读取的扇区数与每磁道扇区数比较
	jne 	ok3_read # 如果不相等，跳转到ok3_read继续读
	mov 	$1, %ax
	sub 	head, %ax
	jne 	ok4_read
	incw    track 
ok4_read:
	mov	%ax, head
	xor	%ax, %ax
ok3_read:
	mov	%ax, sread # 刷新已读取的扇区数(含bootsect/setup那5个扇区)
	shl	$9, %cx
	add	%cx, %bx
	jnc	rp_read
	mov	%es, %ax
	add	$0x1000, %ax # 切到下一段(64KB)读取
	mov	%ax, %es
	xor	%bx, %bx
	jmp	rp_read

read_track:
	push	%ax # ax/bx/cx/dx寄存器压栈保护
	push	%bx
	push	%cx
	push	%dx
	mov	track, %dx # 当前磁道号
	mov	sread, %cx # 当前磁道已读扇区数，初始值5
	inc	%cx # CL=扇区，sread+1=6，即跳过bootsec/setup，从第6扇区开始读
	mov	%dl, %ch # CH=柱面
	mov	head, %dx # DH=磁头 DL=驱动器
	mov	%dl, %dh
	mov	$0, %dl # 驱动器=0表示软盘
	and	$0x0100, %dx 
	mov	$2, %ah # AH=2 读扇区功能，AL=读取扇区出，在ok1_read中，通过sub	sread, %ax设置了磁道剩余扇区数
	int	$0x13 # 读扇区到es:bx中，bx在read_it初始化为0
	jc	bad_rt # CF=0操作成功 CF=1则跳到bad_rt重新开始read_track
	pop	%dx
	pop	%cx
	pop	%bx
	pop	%ax
	ret
bad_rt:	mov	$0, %ax # AH=00H 磁盘系统复位
	mov	$0, %dx # DL=00H~7FH表示软盘
	int	$0x13
	pop	%dx
	pop	%cx
	pop	%bx
	pop	%ax
	jmp	read_track

#/*
# * This procedure turns off the floppy drive motor, so
# * that we enter the kernel in a known state, and
# * don't have to worry about it later.
# */
kill_motor:
	push	%dx
	mov	$0x3f2, %dx
	mov	$0, %al
	outsb
	pop	%dx
	ret

sectors:
	.word 0

msg1:
	.byte 13,10
	.ascii "IceCityOS is booting ..."
	.byte 13,10,13,10

	.org 508
root_dev:
	.word ROOT_DEV
boot_flag:
	.word 0xAA55
	
	.text
	endtext:
	.data
	enddata:
	.bss
	endbss:
