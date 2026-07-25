	.file	"workshare_cancel_assert.c"
	.text
	.local	sink
	.comm	sink,4,4
	.section	.rodata
	.align 8
.LC0:
	.string	"ERROR: OMP_CANCELLATION=true required\nRun with: OMP_CANCELLATION=true OMP_NUM_THREADS=%d LD_LIBRARY_PATH=/tmp/libgomp-build/.libs ./workshare_cancel_assert\n"
	.align 8
.LC1:
	.string	"Testing workshare cancel assertion bug..."
	.align 8
.LC2:
	.string	"If the bug triggers, libgomp will abort() with:"
	.align 8
.LC3:
	.string	"  \"gomp_team_barrier_wait_cancel_end called when barrier cancelled state: ...\"\n"
	.align 8
.LC4:
	.string	"  trial %d completed (no crash yet)\n"
	.align 8
.LC5:
	.string	"\nAll 1000 trials completed without crash."
	.align 8
.LC6:
	.string	"The bug may not have triggered due to timing."
	.text
	.globl	main
	.type	main, @function
main:
.LFB6:
	.cfi_startproc
	endbr64
	pushq	%rbp
	.cfi_def_cfa_offset 16
	.cfi_offset 6, -16
	movq	%rsp, %rbp
	.cfi_def_cfa_register 6
	subq	$32, %rsp
	movq	%fs:40, %rax
	movq	%rax, -8(%rbp)
	xorl	%eax, %eax
	call	omp_get_cancellation@PLT
	testl	%eax, %eax
	jne	.L2
	movq	stderr(%rip), %rax
	movl	$4, %edx
	leaq	.LC0(%rip), %rcx
	movq	%rcx, %rsi
	movq	%rax, %rdi
	movl	$0, %eax
	call	fprintf@PLT
	movl	$1, %eax
	jmp	.L3
.L2:
	leaq	.LC1(%rip), %rax
	movq	%rax, %rdi
	call	puts@PLT
	leaq	.LC2(%rip), %rax
	movq	%rax, %rdi
	call	puts@PLT
	leaq	.LC3(%rip), %rax
	movq	%rax, %rdi
	call	puts@PLT
	movl	$0, -20(%rbp)
	jmp	.L4
.L6:
	movl	$0, %ecx
	movl	$4, %edx
	movl	$0, %esi
	leaq	main._omp_fn.0(%rip), %rax
	movq	%rax, %rdi
	call	GOMP_parallel@PLT
	movl	-20(%rbp), %eax
	leal	1(%rax), %edx
	movslq	%edx, %rax
	imulq	$1374389535, %rax, %rax
	shrq	$32, %rax
	sarl	$5, %eax
	movl	%edx, %ecx
	sarl	$31, %ecx
	subl	%ecx, %eax
	imull	$100, %eax, %ecx
	movl	%edx, %eax
	subl	%ecx, %eax
	testl	%eax, %eax
	jne	.L5
	movl	-20(%rbp), %eax
	addl	$1, %eax
	movl	%eax, %esi
	leaq	.LC4(%rip), %rax
	movq	%rax, %rdi
	movl	$0, %eax
	call	printf@PLT
.L5:
	addl	$1, -20(%rbp)
.L4:
	cmpl	$999, -20(%rbp)
	jle	.L6
	leaq	.LC5(%rip), %rax
	movq	%rax, %rdi
	call	puts@PLT
	leaq	.LC6(%rip), %rax
	movq	%rax, %rdi
	call	puts@PLT
	movl	$0, %eax
.L3:
	movq	-8(%rbp), %rdx
	subq	%fs:40, %rdx
	je	.L7
	call	__stack_chk_fail@PLT
.L7:
	leave
	.cfi_def_cfa 7, 8
	ret
	.cfi_endproc
.LFE6:
	.size	main, .-main
	.type	main._omp_fn.0, @function
main._omp_fn.0:
.LFB7:
	.cfi_startproc
	endbr64
	pushq	%rbp
	.cfi_def_cfa_offset 16
	.cfi_offset 6, -16
	movq	%rsp, %rbp
	.cfi_def_cfa_register 6
	subq	$48, %rsp
	movq	%rdi, -40(%rbp)
	movq	%fs:40, %rax
	movq	%rax, -8(%rbp)
	xorl	%eax, %eax
	call	omp_get_thread_num@PLT
	movl	%eax, -28(%rbp)
	cmpl	$0, -28(%rbp)
	je	.L9
.L10:
	leaq	-16(%rbp), %rdx
	leaq	-24(%rbp), %rax
	movq	%rdx, %r9
	movq	%rax, %r8
	movl	$1, %ecx
	movl	$1, %edx
	movl	$100, %esi
	movl	$0, %edi
	call	GOMP_loop_nonmonotonic_dynamic_start@PLT
	testb	%al, %al
	je	.L11
.L13:
	movq	-24(%rbp), %rax
	movl	%eax, -32(%rbp)
	movq	-16(%rbp), %rax
	movl	%eax, %ecx
.L12:
	movl	sink(%rip), %edx
	movl	-32(%rbp), %eax
	addl	%edx, %eax
	movl	%eax, sink(%rip)
	addl	$1, -32(%rbp)
	cmpl	%ecx, -32(%rbp)
	jl	.L12
	leaq	-16(%rbp), %rdx
	leaq	-24(%rbp), %rax
	movq	%rdx, %rsi
	movq	%rax, %rdi
	call	GOMP_loop_nonmonotonic_dynamic_next@PLT
	testb	%al, %al
	jne	.L13
.L11:
	call	GOMP_loop_end_nowait@PLT
	jmp	.L8
.L9:
	movl	$1, %esi
	movl	$1, %edi
	call	GOMP_cancel@PLT
	testb	%al, %al
	je	.L10
.L8:
	movq	-8(%rbp), %rax
	subq	%fs:40, %rax
	je	.L15
	call	__stack_chk_fail@PLT
.L15:
	leave
	.cfi_def_cfa 7, 8
	ret
	.cfi_endproc
.LFE7:
	.size	main._omp_fn.0, .-main._omp_fn.0
	.ident	"GCC: (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0"
	.section	.note.GNU-stack,"",@progbits
	.section	.note.gnu.property,"a"
	.align 8
	.long	1f - 0f
	.long	4f - 1f
	.long	5
0:
	.string	"GNU"
1:
	.align 8
	.long	0xc0000002
	.long	3f - 2f
2:
	.long	0x3
3:
	.align 8
4:
