# 构建启动

## Makefile

make start对应执行`qemu-system-i386 -m 16M -boot a -fda Image -hda hdc-0.11.img`

- `-boot a`表示从软盘驱动器A启动
- `-fda Image`表示将Image文件作为软盘A；而Image是在build.sh中将bootsect/setup/system三部分内容通过dd写入，具体参考build.sh
- `-hda hdc-0.11.img`表示hdc-0.11.img为硬盘镜像，即根设备；

## build.sh

系统镜像Image由下面三部分构成，通过dd命令将下面三部分写入指定位置：

1. bootsect.s：第1个扇区(512字节)，同时将设备号301（见下图）写到第1扇区末尾，301也就是hda，即上面的hdc-0.11.img

![image-20250809232014014](https://github.com/pozhenzi666/assert/blob/main/images/20250809232014128.png)

2. setup.s：第2~5个扇区（共4个扇区）

3. system：第6~2888扇区，包括head.s、init/main.c等剩余所有内容，不足填充0

![image-20250809231819811](https://github.com/pozhenzi666/assert/blob/main/images/20250809231819923.png)

Image文件内容如上图所示。BIOS规定，上电后它会自动读取第一个扇区到内存0x7c00，并跳转到那里执行；第1扇区也就是bootsect.s。

# boot模块

从下图可以清楚的看到boot模块代码执行过程（箭头指示）：

![image-20250809232038945](https://github.com/pozhenzi666/assert/blob/main/images/20250809231301014.png)

其中涉及到多次代码搬移，比如bootsect.s从0x7c00搬到0x90000，又比如system模块从0x10000搬到0x0000等。

我们可以参考看下实模式下内存布局：

![image-20250809232200766](https://github.com/pozhenzi666/assert/blob/main/images/20250809232200887.png)

## bootsect.s

主要完成以下几项工作：

1. 首先将bootsect从0x7c00搬移到0x90000
2. 将磁盘第2~5扇区搬移到0x90200开始的4个扇区位置
3. 获取并设置软盘的扇区数sectors
4. 打印msg1：IceCityOS is booting ...
5. 拷贝system模块：将第5扇区开始内容，拷贝到0x10000地址起始的192KB空间
6. 设置根设备号root_dev，优先使用构建时设置的值(0x301)，否则根据扇区数进行判断，扇区数为15，设备号设置为0x208；扇区数为18，则设备号设置为0x21c；否则当做不识别设备，启动失败。
7. 跳转到setup.s

## setup.s

此时仍处于实模式下，主要完成以下事情：

1. 打印字符串：Now we are in setup ...
2. 利用BIOS中断读机器系统数据，如下所示（其中0x910FC中的根设备号是在bootsect.s中设置的，其他则是setup.s设置）

![image-20250809232239432](https://github.com/pozhenzi666/assert/blob/main/images/20250809232239536.png)

3. 打印上一步查询到的信息
   1. 打印字符串Cursor POS:<光标位置>
   2. 打印字符串Memory SIZE:<扩展内存数>
   3. 打印字符串HD Info Cylinders:<硬盘参数表：第一个硬盘的磁柱>
   4. 打印字符串Headers:<硬盘参数表：第一个硬盘的磁头>
   5. 打印字符串Secotrs:<硬盘参数表：第一个硬盘的扇区>
   6. 如果第二块硬盘不存在，则将它的参数表(0x90090~0x900A0)清零

4. 移动system模块：将0x10000起始地址内容整体移动到0x0000位置，每次移动64KB，总共移动512KB（实际bootsect.s从磁盘只移动192KB到内存，512KB只是一个上限值）
5. 使用lidt、lgdt分别加载中断描述符表寄存器和全局描述符（保护模式下数据段、代码段信息）表寄存器，操作数都是6字节，存储有两个描述符表的长度和基地址。需要注意的是，6字节表示时是小端存储的。
6. 开启A20地址线，突破1Mb访问限制，
7. 中断8259控制器，包括以下几方面
   1. 设置中断起始范围：主芯片`0x20~0x27`、从芯片`0x28~0x2F`；为什么要设置呢？这是因为x86架构下，`0x00~0x1F`这32个中断号已经被CPU用于保护模式不可更改；而8259A主芯片默认中断号是`0x08~0x0F`，从芯片默认中断号是`0x70~0x77`，这是为了某些历史原因的兼容设计。这样两者就冲突了，因此就需要重新映射。
   2. 设置主从芯片级联关系：从芯片接到主芯片的IRQ2口
   3. 屏蔽主从芯片上所有中断

![image-20250809232257521](https://github.com/pozhenzi666/assert/blob/main/images/20250809232257620.png)

8. 设置CR0寄存器（将PE位置1），自此开始进入保护模式；这些步骤中，5/6/8是从实模式进入保护模式的必备步骤。

![image-20250809232324842](https://github.com/pozhenzi666/assert/blob/main/images/20250809232324942.png)

9. 跳转到system模块最开始的head.s程序继续执行，注意程序使用了ljmp 0x8, 0进行跳转，这是因为当前已经处于保护模式，这里的0x8表示段选择子，0表示段内偏移；段选择子结构如下所示，0x8=1000b，也就是权限级别为0(系统级)、使用全局描述符表gdt，描述符索引是1；

![image-20250809232342584](https://github.com/pozhenzi666/assert/blob/main/images/20250809232342691.png)

索引1就是代码段了，根据配置就是基地址为0x0，大小8M的空间；前面我们将system模块(包含head.s)从0x10000移到了0x000，因此ljmp 0x8,0的作用就是跳转到system模块最开始的位置，也就是head.s中继续执行

![image-20250809232403864](https://github.com/pozhenzi666/assert/blob/main/images/20250809232403958.png)

## head.s

head.s中已经是保护模式了，在这里主要完成如下工作：

1. 设置各段选择子（ds/es/fs/gs/ss）
2. 设置256个中断描述符(setup_idt，注意这里是中断门，除了中断门还有任务门、陷阱门)，中断处理函数都默认指向ignore_int；设置完后将中断描述符地址加载到idt寄存器

![image-20250809232423359](https://github.com/pozhenzi666/assert/blob/main/images/20250809232423457.png)

3. 设置全局段描述符(setup_gdt)，虽然在setup.s中设置过8MB，但此时已经改成了16MB，因此有必要重新设置

4. 再次检查A20线是否使能，若否则一直循环检查

5. 设置CR0寄存器：设置PG（分页）、PE（保护模式开启）、ET（判断协处理器是80287还是80387）；如果存在数字协处理器，则设置EM已启用协处理器、MP（协处理器存在标志）

6. 设置页表setup_paging：页表位于head.s起始位置，也就是0x0000开始，一共设置了5页（1个页目录+4个页表），设置时从第4个页表最后一项，从高往低设置页表内容（初始0xfff007，每次减0x1000），经过此设置后内存布局如下图所示

![image-20250809232441837](https://github.com/pozhenzi666/assert/blob/main/images/20250809232441939.png)

7. 设置页目录基地址到cr3寄存器，然后设置cr0寄存器PG位开启分页

8. 跳转到C语言中main

# init模块

## 内存初始化-mem_init

在setup.s中，已经通过BIOS查出扩展内存(超过1M部分)大小，并存在0x9000C处。内存初始化时先根据内存大小设置内存相关全局变量

![image-20250809232459717](https://github.com/pozhenzi666/assert/blob/main/images/20250809232459807.png)

然后mem_init将main_memory_start与memory_end之间内存通过数组mem_map管理起来，数组下表0对应1M内存处（低1M留给BIOS、显存等，不纳入内存管理，但页表为前16M都建立好了映射），每4K内存对应一个数组项，最多管理15M空间，也就是mem_map管理内存为1~16M，共(16-1)*1024/4=3840项。

数组值为0或1，0表示未被使用，1表示被使用。free_page释放页时根据物理地址找到数组索引，然后将数组值改为0；

## 陷阱门初始化-trap_init

trap_init中设置陷阱门，编号`0~47，其中包括`3~5`这三个系统门（任意特权级都可以调用的陷阱门），我们这里需要对陷阱门、中断门、系统门这些概念做个区分：

- 陷阱门：CPU异常（0~31，除去3/4/5），发生异常时不会改变IF标志（可屏蔽中断标识，即可被其他中断打断）；这些异常时x86定义的不可改变，根据其行为特征又可以分为Fault/Trap/Abort三种，具体可以参考《Intel 64 and IA32 Architectures Software Developer's Manual》中卷3的6.3.1章节表6.1看每种异常所属类型
- 中断门：硬件中断（32~47），发生中断时自动清除IF标识
- 系统门：用户态可以调用的陷阱门（3/4/5/128），如int 0x80（即128）系统调用

![image-20250809232522527](https://github.com/pozhenzi666/assert/blob/main/images/20250809232522634.png)

trap_init中设置陷阱门也就是设置发生异常或中断时，对应的处理函数。这三种类型门对应的处理函数其实就是idt中设置的中断向量，在linux 0.11代码中默认共有256个，在head.s中当时我们给这256项都设置的ignore_int这个处理函数，trap_init相当于重新设置其中部分处理函数了。

BTW：x86硬件还提供有任务门，用来支持硬件实现任务切换或进程管理，但linux没有采用该机制，而是通过软件实现任务切换。—— 更加灵活

## 块设备初始化-blk_dev_init

初始化代码相当简单（如下），linux 0.11内核中主要支持硬盘和软盘两种块设备

```c
void blk_dev_init(void)
{
	int i;

	for (i=0 ; i<NR_REQUEST ; i++) {
		request[i].dev = -1;
		request[i].next = NULL;
	}
}
```

其中NR_REQUEST=32，相当于一个32层的电梯。在每次add_request的时候相当于按下了一个电梯，操作系统将根据电梯算法调度访问磁盘。电梯算法介绍可以参考：https://blog.csdn.net/qq_31442743/article/details/129599000

## 字符设备初始化-chr_dev_init

函数实现为空；

因为字符设备的访问是同步直调的，不像块设备需要进行调度访问。

## tty终端初始化-tty_init

tty设备也属于字符设备，因为较特殊，单独初始化。它分为两部分rs_init和con_init。

### rs_init——串口初始化

1. 设置IRQ3、IRQ4的中断处理函数为rs1_interrupt、rs2_interrupt
2. 初始化串口1、串口2
3. 打开IRQ3、IRQ4中断，自此可以接收这两个中断，并请将中断请求交给rs1_interrupt、rs2_interrupt处理。

### con_init——终端屏幕初始化

1. 根据setup.s中获取的机器信息，设置终端屏幕显示相关的全局变量，如每行显示字节数、当前页面、起始内存地址等；对于内存地址来说，单色EGA范围`0xb0000~0xb8000`，单色MDA范围`0xb0000~0xb2000`，彩色EGA范围`0xb8000~0xbc000`，彩色CGA范围`0xb8000~0xba000`，在屏幕上显示字符即往这块内存写入字符，也就是下面的显存位置

![image-20250810081725458](https://github.com/pozhenzi666/assert/blob/main/images/20250810081725570.png)

2. 设置键盘中断向量，中断号0x21（IRQ1），中断处理函数keyboard_interrupt；
3. 设置键盘中断后通过`outb_p(inb_p(0x21)&0xfd,0x21)`打开该中断
4. 最后控制8255A芯片0x61端口，产生一个蜂鸣器声音

![image-20250810112520972](https://github.com/pozhenzi666/assert/blob/main/images/20250810112521174.png)

## 日期时间初始化-time_init

1. 从CMOS中读日期、时间信息，读取内容如下几个偏移位置；

![image-20250810121554587](https://github.com/pozhenzi666/assert/blob/main/images/20250810121554704.png)

2. 将上一步读取BCD码日期时间信息转成十进制，然后转出unix时间戳（1970/1/1开始至今的秒数）存储到全局变量startup_time

注：BCD码是4位二进制表示1位十进制，如十进制的29对应的BCD码为0010 1001

## 调度初始化——sched_init

1. 设置任务0~63共64个任务的tss和ldt描述符；其中任务0设置为init_task，其他任务的tss和ldt初始化为0

![image-20250810164140747](https://github.com/pozhenzi666/assert/blob/main/images/20250810164140893.png)

2. 加载任务的tss/ldt到任务寄存器tr和局部描述符寄存器
3. 配置8253定时器工作评率为100Hz（每10ms一次中断），因为8293定时器时钟频率为1193180Hz，我们目标频率为100hz，那么就将LATCH作为初值设置到定时器，他将从这个值开始每次-1，直到等于0时触发中断，随后又从初始值-1，如此循环。

```c
#define HZ 100                    // 系统时钟频率：100Hz
#define LATCH (1193180/HZ)        // 定时器初值：1193180/100 = 11931，每次时钟周期-1，等于0时产生一个中断，后面又从初值开始计数，依次得到一个稳定的系统时钟频率
```

4. 设置时钟中断（IRQ0）的中断向量为timer_interrupt，并且使能时钟中断，后面就可以依赖此中断进行任务调度等操作了。
5. 设置0x80中断的向量为system_call，也就是系统调用 

## 高速缓冲初始化——buffer_init

1. 设置buffer_head：以.bss段之后首个地址end作为缓冲区起始地址start_buffer，也就是buffer_head

   注意end这个地址是ld链接器设置的，在linux-0.11代码中LD链接时由于未通过-T指定自定义链接脚本，因此它会使用隐式链接脚本（可以通过ld --verbose查看），在隐式链接脚本中有类似如下代码，设置end为.bss段后起始地址；

```Makefile
.bss : { *(.bss) }
end = .; 
```

​	end同样可以在编译出的System.map找到，会发现其位置正是.map末尾

2. 设置buffer_end：如果整个扩展内存超过12M，则buffer_head=4M；否则如果超过6M，则buffer_head=2M；否则不足6M，则buffer_end=640K

3. 从buffer_end开始递减，每1K（跟逻辑块大小一致）作为一个buffer块，设置其对应的管理结构buffer头，每个buffer头36字节，从buffer_head开始递增

![image-20250810211611042](https://github.com/pozhenzi666/assert/blob/main/images/20250810211611164.png)

最终得到下面这样一个buffer链表

![image-20250810211900308](https://github.com/pozhenzi666/assert/blob/main/images/20250810211900425.png)

注意，在buffer缓冲区中存在显存和BIOS ROM区，在设置buffer块/buffer头的时候，会对该地址进行检测并跳过他，保证此区域不被破坏

![image-20250810212348882](https://github.com/pozhenzi666/assert/blob/main/images/20250810212348992.png)

## 硬盘初始化——hd_init

1. 设置硬盘设备请求函数request_fn

对硬盘/软盘等块设备读写时都会向缓冲区管理程序提出申请，而程序的进程则进入睡眠等待状态。缓冲区管理程序首先在缓冲区中寻找以前是否已经读取过这块数据。如果缓冲区中已经有了，就直接将对应的缓冲区块头指针返回给程序并唤醒该程序进程。若缓冲区中不存在所要求的数据块，则缓冲管理程序就会调用本章中的低级块读写函数1l_rw_block)，向相应的块设备驱动程序发出一个读数据块的操作请求。该函数就会为此创建一个请求结构项，并插入请求队列中。最终电梯算法调度执行该块设备请求，并使用request_fn进行数据读写操作。

请求函数通过宏*MAJOR_NR*进行隔离，由于“构建启动->buildsh”阶段，我们设置了MAJOR_NR=3，因此request_fn最终被设置为do_hd_request

![image-20250810214336777](https://github.com/pozhenzi666/assert/blob/main/images/20250810214336900.png)

2. 设置硬盘中断(IRQ14)中断处理函数为hd_interrupt，并且把IRQ2中断使能（IRQ2链接到从8295A中断控制器，而IRQ14正好在8295A从控制器上），最好把IRQ14使能

## 软盘初始化——floppy_init

1. 设置软盘设备请求函数request_fn

注意，本文件中MAJOR_NR设置为2，覆盖了build.sh中设置的3，因此DEVICE_REQUEST将指向do_fd_request并设置到blk_dev数组中

![image-20250810215633594](https://github.com/pozhenzi666/assert/blob/main/images/20250810215633714.png)

2. 设置软盘中断IRQ6处理函数floppy_interrupt，然后使能该中断

## 切到用户态——move_to_user_mode

该函数主要功能是将程序流从内核态（特权级0）切到用户态（特权级3）的进程0执行，进程0也就是前面sched_init中设置过得init_task。

他利用中断返回指令iret实现特权级切换，主要思想是在堆栈中构筑中断返回指令需要的内容，把返回地址的段选择符设置成任务0代码段选择符（特权级为3），然后执行iret即可。下面是具体解释

![image-20250811012525316](https://github.com/pozhenzi666/assert/blob/main/images/20250811012525483.png)

这里对段选择子再说明下，0x17也就是0001 0111，参考下图TI=0表示从GDT表查找描述符，段描述符索引=1（结合TI=0表示GDT表第二项，即数据段），RPL=3表示用户态：

![image-20250810234452695](https://github.com/pozhenzi666/assert/blob/main/images/20250810234452800.png)

## 进程复制——fork

### system_call实现原理

1. fork实现就是int 0x80中断（syscall0也就是0个入参的系统调用，此外还有syscall1/syscall2...），而在前面调度初始化sched_init中，设置过0x80中断的处理函数为system_call

```c
#define __NR_fork	2
#define _syscall0(type,name) \
  type name(void) \
{ \
long __res; \
__asm__ volatile ("int $0x80" \
	: "=a" (__res) \
	: "0" (__NR_##name)); \
if (__res >= 0) \
	return (type) __res; \
errno = -__res; \
return -1; \
}
    
static inline _syscall0(int,fork)
```

2. system_call的实现在system_call.s中，他利用第一步传入的__NR_fork=2作为下表，从sys_call_table中找到具体实现即sys_fork，然后使用call指令调用该函数。

- 首先，call指令执行时，CPU会将SS:ESP、EFLAGS、CS:EIP这几个寄存器信息自动压栈，不需要软件介入，这些信息在iret的时候会再恢复：

![image-20250812003834606](https://github.com/pozhenzi666/assert/blob/main/images/20250812003834726.png)

-  然后内核将ds/es/fs这几个段寄存器保护压栈，再将edx/ecx/ebx这三个寄存器信息压栈（其中存有系统调用参数，也就是说当前系统支持的系统调用最多3个参数）
- 接着执行call指令，运行sys_call_talbe中找到的系统调用实现，这里是sys_fork。
- 执行完之后函数返回值保存在eax寄存器，需要压栈
- 然后判断是否需要重新调度：如任务不再处于running状态，或者时间片已经用完，那么需要重新调度切到其他任务。否则从内核态回到用户态，仍在当前任务。

### reschedule

代码只有两行，首先将返回地址压栈，这是因为下面一行代码jmp是无条件跳转，它不会保存返回地址，而schedule函数在sched.c中定义，是一个c语言函数，需要遵循C函数调用约定；这样的话，下面两行就相当于call schedule了（call指令会自动将返回地址压栈）

```asm
pushl $ret_from_sys_call
jmp schedule
```

而这里选择ret_from_sys_call作为返回地址，则是为了保证切任务后，原来任务的返回值等信息仍能够正确返回。

> 说明：我们不用担心切任务后原来保存的栈信息被踩，因为每个人物都有独立的栈和内存空间，在switch_to切任务的时候会将他们妥善保护好。

### ret_from_sys_call

在系统调用结束前，或者schedule执行后，都会调用ret_from_sys_call来恢复栈信息。首先会判断是否有信号需要处理：

1. 如果当前任务是task0，说明一定不会有信号，那么直接执行**弹栈流程**：弹出eax/ebx/ecx/edx/fs/es/ds到寄存器，再iret弹出cs:eip、efalgs、ss:esp等。
2. 然后判断当前任务是否为内核任务（通过RPL判断），如果是的话也是直接执行**弹栈流程**；
3. 否则进行信号处理

### sys_fork

1. find_empty_process: 从task数组中，找一个空闲的task
2. 参数压栈：将gs/esi/edi/ebp/eax寄存器压栈，加上system_call中压入的ds/es/fs/edx/ecx/ebx，再加上int 0x80中断时cpu自动压入的eip/cs/eflags/esp/ss寄存器，一起作为等会儿copy_process的入参
3. 执行copy_process，他将新申请一页存储current任务的task_struct信息，然后设置其中的各字段
4. 接下来是关键点：把新任务的tss/ldt加到gdt表中的tss/ldt去，设置好之后新的task就可以等待被调度了。等到下次调度时，由于新任务的eip跟原来任务一样，因此也从同样位置执行。
5. 原来的任务在copy_process后继续执行

> 说明：sys_fork调用一次，返回两次的关键就在于新创建的task关键内容与原任务task_struct一致，尤其是tss信息；这样的话等到新任务被调度时，就从原任务指定的位置继续执行，看起来就像是返回两次一样。实际是两次是在不同的调度周期，只不过eip一样罢了。

## 初始化——init

1. 执行sys_setup系统调用，他将利用boot/setup.s提供信息对系统中硬盘驱动器参数进行设置；然后读取硬盘分区表，并尝试把启动引导盘上的虚拟根文件系统映像文件复制到内存虚拟盘中，若成功则加载虚拟盘中的根文件系统，否则继续执行普通根文件系统加载操作。
   1. 根据传入的BIOS地址，将BIOS中2块硬盘信息存储到全局变量hd_info中，然后根据hd_info信息设置hd全局变量，存储了两块硬盘的起始扇区（默认0）以及扇区个数（head \* sect \* cyl）
   2. 找到启动盘，读取其中分区表信息中的start_sect和nr_sects，分区表结构如下所示：
   
   ![image-20250817000634915](https://github.com/pozhenzi666/assert/blob/main/images/20250817000635099.png)

2. 打开/dev/tty0设备文件，将他作为标准输入fd=0
3. 接着dup(0)两次，即复制fd=0两次，得到fd=1（标准输出）/fd=2（标准错误）
4. fork子进程，子进程以/etc/rc作为标准输入，即执行其中系统初始化脚本；然后execve("/bin/sh")让子进程进入到shell
5. 父进程等待子进程结束，即一直处于shell窗口
6. 子进程退出后又重复上面步骤，效果是一直处于shell窗口中
