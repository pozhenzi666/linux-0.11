/*
 *  linux/kernel/system_call.s
 *
 *  (C) 1991  Linus Torvalds
 */

/*
 *  system_call.s  contains the system-call low-level handling routines.
 * This also contains the timer-interrupt handler, as some of the code is
 * the same. The hd- and flopppy-interrupts are also here.
 *
 * NOTE: This code handles signal-recognition, which happens every time
 * after a timer-interrupt and after each system call. Ordinary interrupts
 * don't handle signal-recognition, as that would clutter them up totally
 * unnecessarily.
 *
 * Stack layout in 'ret_from_system_call':
 *
 *	 0(%esp) - %eax
 *	 4(%esp) - %ebx
 *	 8(%esp) - %ecx
 *	 C(%esp) - %edx
 *	10(%esp) - %fs
 *	14(%esp) - %es
 *	18(%esp) - %ds
 *	1C(%esp) - %eip
 *	20(%esp) - %cs
 *	24(%esp) - %eflags
 *	28(%esp) - %oldesp
 *	2C(%esp) - %oldss
 */

SIG_CHLD	= 17

EAX		= 0x00
EBX		= 0x04
ECX		= 0x08
EDX		= 0x0C
FS		= 0x10
ES		= 0x14
DS		= 0x18
EIP		= 0x1C
CS		= 0x20
EFLAGS		= 0x24
OLDESP		= 0x28
OLDSS		= 0x2C

state	= 0		# these are offsets into the task-struct.
counter	= 4
priority = 8
signal	= 12
sigaction = 16		# MUST be 16 (=len of sigaction)
blocked = (33*16)

# offsets within sigaction
sa_handler = 0
sa_mask = 4
sa_flags = 8
sa_restorer = 12

nr_system_calls = 74

/*
 * Ok, I get parallel printer interrupts while using the floppy for some
 * strange reason. Urgel. Now I just ignore them.
 */
.globl system_call,sys_fork,timer_interrupt,sys_execve
.globl hd_interrupt,floppy_interrupt,parallel_interrupt
.globl device_not_available, coprocessor_error

.align 2
bad_sys_call:
	movl $-1,%eax
	iret
.align 2
reschedule:
	pushl $ret_from_sys_call # 由于schedule定义在sched.c中，他是一个c函数，需要遵循c语言的函数调用规则，所以需要将ret_from_sys_call标签的地址压入栈中
	jmp schedule # jmp指令是无条件跳转，不会报错返回地址，而上一步将返回地址push压栈，组合起来相当于call schedule，保证原来系统调用返回值等信息还在
.align 2
system_call:
	cmpl $nr_system_calls-1,%eax
	ja bad_sys_call
	push %ds # 从这行开始，将ds/es/fs/edx/ecx/ebx压栈，这些在后面copy_process中会用到
	push %es
	push %fs
	pushl %edx
	pushl %ecx		# push %ebx,%ecx,%edx as parameters 最多支持三个参数
	pushl %ebx		# to the system call
	movl $0x10,%edx		# set up ds,es to kernel space
	mov %dx,%ds # 进入内核态后，ds/es寄存器指向内核数据段
	mov %dx,%es
	movl $0x17,%edx		# fs points to local data space
	mov %dx,%fs # 进入内核态后，fs寄存器指向进程数据段
	call *sys_call_table(,%eax,4)
	pushl %eax # eax: 保存系统调用返回值
	movl current,%eax # current: sched.c中定义，指向task_struct结构体，表示当前任务（进程）数据结构
	cmpl $0,state(%eax)		# state:由于eax寄存器已保存task_struct结构体地址，所以state(%eax)表示task_struct结构体中的state字段
	jne reschedule # 0表示进程处于运行状态，如果为0，则跳转到reschedule标签，重新调度进程
	cmpl $0,counter(%eax)   # counter:task_struct中字段，表示进程的运行时间片
	je reschedule # 如果counter为0（表示进程运行时间片已用完），则跳转到reschedule标签，重新调度进程
ret_from_sys_call:
	movl current,%eax		# task[0] cannot have signals
	cmpl task,%eax # task[0]是idle进程，不能有信号，这里判断是否是idle进程，是的话直接跳转到3f标签弹出栈中保存的系统调用返回值等信息
	je 3f
	cmpw $0x0f,CS(%esp)		# was old code segment supervisor ?
	jne 3f
	cmpw $0x17,OLDSS(%esp)		# was stack segment = 0x17 ?
	jne 3f
	movl signal(%eax),%ebx
	movl blocked(%eax),%ecx
	notl %ecx
	andl %ebx,%ecx
	bsfl %ecx,%ecx
	je 3f
	btrl %ecx,%ebx
	movl %ebx,signal(%eax)
	incl %ecx
	pushl %ecx
	call do_signal
	popl %eax
3:	popl %eax
	popl %ebx
	popl %ecx
	popl %edx
	pop %fs
	pop %es
	pop %ds
	iret

.align 2
coprocessor_error:
	push %ds
	push %es
	push %fs
	pushl %edx
	pushl %ecx
	pushl %ebx
	pushl %eax
	movl $0x10,%eax
	mov %ax,%ds
	mov %ax,%es
	movl $0x17,%eax
	mov %ax,%fs
	pushl $ret_from_sys_call
	jmp math_error

.align 2
device_not_available:
	push %ds
	push %es
	push %fs
	pushl %edx
	pushl %ecx
	pushl %ebx
	pushl %eax
	movl $0x10,%eax
	mov %ax,%ds
	mov %ax,%es
	movl $0x17,%eax
	mov %ax,%fs
	pushl $ret_from_sys_call
	clts				# clear TS so that we can use math
	movl %cr0,%eax
	testl $0x4,%eax			# EM (math emulation bit)
	je math_state_restore
	pushl %ebp
	pushl %esi
	pushl %edi
	call math_emulate
	popl %edi
	popl %esi
	popl %ebp
	ret

.align 2
timer_interrupt:
	push %ds		# save ds,es and put kernel data space /// 保存被打断的寄存器ds/es/fs
	push %es		# into them. %fs is used by _system_call
	push %fs
	pushl %edx		# we save %eax,%ecx,%edx as gcc doesn't /// 根据C语言调用惯例(cdecl)，eax/ecx/edx寄存器值由caller-saved
	pushl %ecx		# save those across function calls. %ebx
	pushl %ebx		# is saved as we use that in ret_sys_call /// ebx寄存器因为后面ret_from_sys_call使用到，因此提前保护
	pushl %eax
	movl $0x10,%eax # /// 0x10 内核数据段选择子
	mov %ax,%ds 
	mov %ax,%es
	movl $0x17,%eax # /// 0x17是当前进程用户数据段选择子(RPL=3)
	mov %ax,%fs
	incl jiffies
	movb $0x20,%al		# EOI to interrupt controller #1 /// 手动发送EOI结束中断给8259A芯片，允许中断控制器继续排队新的相同IRQ
	outb %al,$0x20 # /// （EOI只是解除中断控制器的忙状态，实际能否进入取决于IF与优先级，此时IF被中断门自动清零了）
	movl CS(%esp),%eax # /// CS=0x20，刚好是栈中cs偏移，整个栈包括cpu自动压的以及刚好压入的，偏移值如 eax=0,ebx=4 ecx=8 edx=0xc fs=0x10 ... cs=0x20
	andl $3,%eax		# %eax is CPL (0 or 3, 0=supervisor) /// andl $3,%eax将取出eax寄存器低2位，eax是cs即内核或用户段选择子，低2位也就是CPL值
	pushl %eax
	call do_timer		# 'do_timer(long CPL)' does everything from
	addl $4,%esp		# task switching to accounting ...
	jmp ret_from_sys_call

.align 2
sys_execve:
	lea EIP(%esp),%eax
	pushl %eax
	call do_execve
	addl $4,%esp
	ret

.align 2
sys_fork:
	call find_empty_process # 找一个空闲进程槽位，并返回进程号，如果失败，则返回-11
	testl %eax,%eax
	js 1f # 如果eax寄存器为负数，则跳转到1f标签，直接返回
	push %gs # 开始压入gs/esi/edi/ebp/eax寄存器，加上system_call中压入的ds/es/fs/edx/ecx/ebx，
	pushl %esi # 还有Int 0x80时自动压入的eip/cs/eflags/esp/ss寄存器，一起作为copy_process的参数
	pushl %edi
	pushl %ebp
	pushl %eax
	call copy_process
	addl $20,%esp
1:	ret

hd_interrupt:
	pushl %eax
	pushl %ecx
	pushl %edx
	push %ds
	push %es
	push %fs
	movl $0x10,%eax
	mov %ax,%ds
	mov %ax,%es
	movl $0x17,%eax
	mov %ax,%fs
	movb $0x20,%al
	outb %al,$0xA0		# EOI to interrupt controller #1
	jmp 1f			# give port chance to breathe
1:	jmp 1f
1:	xorl %edx,%edx
	xchgl do_hd,%edx
	testl %edx,%edx
	jne 1f
	movl $unexpected_hd_interrupt,%edx
1:	outb %al,$0x20
	call *%edx		# "interesting" way of handling intr.
	pop %fs
	pop %es
	pop %ds
	popl %edx
	popl %ecx
	popl %eax
	iret

floppy_interrupt:
	pushl %eax
	pushl %ecx
	pushl %edx
	push %ds
	push %es
	push %fs
	movl $0x10,%eax
	mov %ax,%ds
	mov %ax,%es
	movl $0x17,%eax
	mov %ax,%fs
	movb $0x20,%al
	outb %al,$0x20		# EOI to interrupt controller #1
	xorl %eax,%eax
	xchgl do_floppy,%eax
	testl %eax,%eax
	jne 1f
	movl $unexpected_floppy_interrupt,%eax
1:	call *%eax		# "interesting" way of handling intr.
	pop %fs
	pop %es
	pop %ds
	popl %edx
	popl %ecx
	popl %eax
	iret

parallel_interrupt:
	pushl %eax
	movb $0x20,%al
	outb %al,$0x20
	popl %eax
	iret
