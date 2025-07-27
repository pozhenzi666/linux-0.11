/*
 *  linux/boot/head.s
 *
 *  (C) 1991  Linus Torvalds
 */

/*
 *  head.s contains the 32-bit startup code.
 *
 * NOTE!!! Startup happens at absolute address 0x00000000, which is also where
 * the page directory will exist. The startup code will be overwritten by
 * the page directory.
 */
.text
.globl idt,gdt,pg_dir,tmp_floppy_area
pg_dir: # pg_dir跟startup_32在同一行，因此pg_dir的地址也是0x0000，pg_dir会覆盖startup_32
.globl startup_32
startup_32:
	movl $0x10,%eax # 0x10 是内核数据段选择子，指向setup.s中gdt定义的第2个段描述符(数据段描述符)
	mov %ax,%ds # 代码段在ljmp	$sel_cs0, $0中已经加载到cs寄存器中，这里只需要加载数据段到ds、es、fs、gs寄存器中
	mov %ax,%es
	mov %ax,%fs
	mov %ax,%gs
	lss stack_start,%esp # 将内存stack_start定义的栈段选择子和栈指针加载到ss:esp，stack_start在sched.c中定义
	call setup_idt
	call setup_gdt # 段长度从8MB(setup.s)扩展到16MB，因此有必要重新设置
	movl $0x10,%eax		# reload all the segment registers
	mov %ax,%ds		# after changing gdt. CS was already
	mov %ax,%es		# reloaded in 'setup_gdt'
	mov %ax,%fs
	mov %ax,%gs
	lss stack_start,%esp
	xorl %eax,%eax
1:	incl %eax		# check that A20 really IS enabled
	movl %eax,0x000000	# loop forever if it isn't
	cmpl %eax,0x100000
	je 1b

/*
 * NOTE! 486 should set bit 16, to check for write-protect in supervisor
 * mode. Then it would be unnecessary with the "verify_area()"-calls.
 * 486 users probably want to set the NE (#5) bit also, so as to use
 * int 16 for math errors.
 */
	movl %cr0,%eax		# check math chip
	andl $0x80000011,%eax	# Save PG(Paging),PE(Protection Enable),ET(扩展位，判断协处理器是80287还是80387)
/* "orl $0x10020,%eax" here for 486 might be good */
	orl $2,%eax		# set MP(Math Present-协处理器存在标志)
	movl %eax,%cr0
	call check_x87
	jmp after_page_tables

/*
 * We depend on ET to be correct. This checks for 287(80286处理器的协处理器)/387(80386处理器的协处理器).
 */
check_x87:
	fninit # 初始化协处理器
	fstsw %ax # 将协处理器状态字寄存器(FPU状态字)中的状态字保存到ax寄存器中
	cmpb $0,%al # 如果ax寄存器中的值为0，则表示协处理器不存在
	je 1f			/* no coprocessor: have to set bits */ # 如果协处理器不存在，则设置MP(Math Present-协处理器存在标志)和EM(Math Error-协处理器错误标志)
	movl %cr0,%eax
	xorl $6,%eax		/* reset MP, set EM(Emulation 启用协处理器模拟) */
	movl %eax,%cr0
	ret
.align 2
1:	.byte 0xDB,0xE4		/* fsetpm for 287, ignored by 387 */
	ret

/*
 *  setup_idt
 *
 *  sets up a idt with 256 entries pointing to
 *  ignore_int, interrupt gates. It then loads
 *  idt. Everything that wants to install itself
 *  in the idt-table may do so themselves. Interrupts
 *  are enabled elsewhere, when we can be relatively
 *  sure everything is ok. This routine will be over-
 *  written by the page tables.
 */
setup_idt:
	lea ignore_int,%edx # ignore_int 默认中断处理函数
	movl $0x00080000,%eax # 0x0008 是内核代码段选择子，0x0000 是段内偏移
	movw %dx,%ax		/* selector = 0x0008 = cs */ # eax存储中断处理函数地址(0x00080000+ignore_int)
	movw $0x8E00,%dx	/* interrupt gate - dpl=0, present(P=1,表示中断门存在) */ # 0x8E00表示中断门，此外还有任务门、陷阱门

	lea idt,%edi # idt 是中断描述符表，存储有256个中断描述符
	mov $256,%ecx
rp_sidt: # 对于中断描述符来说有三种：中断门、陷阱门、任务门，对于中断门来说，低32位存储中断处理函数地址(段选择子+段内偏移[15:0])，
	movl %eax,(%edi) # 将eax中的中断处理函数地址写入到idt中
	movl %edx,4(%edi) # 将edx中的中断门描述符写入到idt中
	addl $8,%edi # 指向下一个中断描述符
	dec %ecx
	jne rp_sidt
	lidt idt_descr # 加载idt描述符(idt_descr)到idt寄存器中(此时256个中断描述符已全部加载到idt中)
	ret

/*
 *  setup_gdt
 *
 *  This routines sets up a new gdt and loads it.
 *  Only two entries are currently built, the same
 *  ones that were built in init.s. The routine
 *  is VERY complicated at two whole lines, so this
 *  rather long comment is certainly needed :-).
 *  This routine will beoverwritten by the page tables.
 */
setup_gdt:
	lgdt gdt_descr
	ret

/*
 * I put the kernel page tables right after the page directory,
 * using 4 of them to span 16 Mb of physical memory. People with
 * more than 16MB will have to expand this.
 */
.org 0x1000 # .org汇编器地址定位指令，告诉汇编器从这里开始的代码应该放在0x1000
pg0: # 结合上一行代码，意思是pg0对应的地址是0x1000

.org 0x2000
pg1:

.org 0x3000
pg2:

.org 0x4000
pg3:

.org 0x5000
/*
 * tmp_floppy_area is used by the floppy-driver when DMA cannot
 * reach to a buffer-block. It needs to be aligned, so that it isn't
 * on a 64kB border.
 */
tmp_floppy_area:
	.fill 1024,1,0

after_page_tables:
	pushl $0		# These are the parameters to main :-) # main函数参数:envp
	pushl $0 # main函数参数:argv
	pushl $0 # main函数参数:argc
	pushl $L6		# return address for main, if it decides to. # main函数返回地址
	pushl $main # 设置完分页后，跳转到main函数
	jmp setup_paging
L6:
	jmp L6			# main should never return here, but
				# just in case, we know what happens.

/* This is the default interrupt "handler" :-) */
int_msg:
	.asciz "Unknown interrupt\n\r"
.align 2
ignore_int:
	pushl %eax
	pushl %ecx
	pushl %edx
	push %ds
	push %es
	push %fs
	movl $0x10,%eax
	mov %ax,%ds
	mov %ax,%es
	mov %ax,%fs
	pushl $int_msg
	call printk
	popl %eax
	pop %fs
	pop %es
	pop %ds
	popl %edx
	popl %ecx
	popl %eax
	iret


/*
 * Setup_paging
 *
 * This routine sets up paging by setting the page bit
 * in cr0. The page tables are set up, identity-mapping
 * the first 16MB. The pager assumes that no illegal
 * addresses are produced (ie >4Mb on a 4Mb machine).
 *
 * NOTE! Although all physical memory should be identity
 * mapped by this routine, only the kernel page functions
 * use the >1Mb addresses directly. All "normal" functions
 * use just the lower 1Mb, or the local data space, which
 * will be mapped to some other place - mm keeps track of
 * that.
 *
 * For those with more memory than 16 Mb - tough luck. I've
 * not got it, why should you :-) The source is here. Change
 * it. (Seriously - it shouldn't be too difficult. Mostly
 * change some constants etc. I left it at 16Mb, as my machine
 * even cannot be extended past that (ok, but it was cheap :-)
 * I've tried to show which constants to change by having
 * some kind of marker at them (search for "16Mb"), but I
 * won't guarantee that's all :-( )
 */
.align 2
setup_paging:
	movl $1024*5,%ecx		/* 5 pages - pg_dir+4 page tables */
	xorl %eax,%eax
	xorl %edi,%edi			/* pg_dir is at 0x000 */
	cld;rep;stosl
	movl $pg0+7,pg_dir		/* set present bit/user r/w */ # pg_dir页目录第一项指向0x1000，第一个页表
	movl $pg1+7,pg_dir+4		/*  --------- " " --------- */ # pg_dir页目录第二项指向0x2000，第二个页表
	movl $pg2+7,pg_dir+8		/*  --------- " " --------- */ # pg_dir页目录第三项指向0x3000，第三个页表
	movl $pg3+7,pg_dir+12		/*  --------- " " --------- */ # pg_dir页目录第四项指向0x4000，第四个页表
	movl $pg3+4092,%edi # 将pg3+4092的值赋值给edi寄存器，pg3+4092的值为0x4000+4092=0x7fff，表示第4个页表最后一个页表项(一个页表有1024个页表项，一个页表项4字节，因此最后一个页表项的地址为0x4000+4092=0x7fff)的地址
	movl $0xfff007,%eax		/*  16Mb - 4096 + 7 (r/w user,p) */
	std
1:	stosl			/* fill pages backwards - more efficient :-) */ # stosl: eax -> es:edi，然后edi-4(std)或者edi+4(cld)
	subl $0x1000,%eax
	jge 1b
	cld
	xorl %eax,%eax		/* pg_dir is at 0x0000 */
	movl %eax,%cr3		/* cr3 - page directory start */
	movl %cr0,%eax
	orl $0x80000000,%eax
	movl %eax,%cr0		/* set paging (PG) bit */
	ret			/* this also flushes prefetch-queue */

.align 2
.word 0
idt_descr:
	.word 256*8-1		# idt contains 256 entries
	.long idt
.align 2
.word 0
gdt_descr:
	.word 256*8-1		# so does gdt (not that that's any
	.long gdt		# magic number, but it works for me :^)

	.align 8
idt:	.fill 256,8,0		# idt is uninitialized
# setup.s中定义的gdt是8MB，这里定义的是16MB，其他跟setup.s中定义的gdt一样
gdt:	.quad 0x0000000000000000	/* NULL descriptor */
	.quad 0x00c09a0000000fff	/* 16Mb */
	.quad 0x00c0920000000fff	/* 16Mb */
	.quad 0x0000000000000000	/* TEMPORARY - don't use */
	.fill 252,8,0			/* space for LDT's and TSS's etc */
