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

tty设备也属于字符设备，因为较特殊，单独初始化。
