/*	$NetBSD: copy.S,v 1.31 2019/05/04 08:50:39 maxv Exp $	*/

/*
 * Copyright (c) 1998, 2000, 2004, 2008 The NetBSD Foundation, Inc.
 * All rights reserved.
 *
 * This code is derived from software contributed to The NetBSD Foundation
 * by Charles M. Hannum.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE NETBSD FOUNDATION, INC. AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * Copyright (c) 1990 The Regents of the University of California.
 * All rights reserved.
 *
 * This code is derived from software contributed to Berkeley by
 * William Jolitz.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of the University nor the names of its contributors
 *    may be used to endorse or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 *
 *	@(#)locore.s	7.3 (Berkeley) 5/13/91
 */

#include <machine/asm.h>
__KERNEL_RCSID(0, "$NetBSD: copy.S,v 1.31 2019/05/04 08:50:39 maxv Exp $");

#include "assym.h"

#include <sys/errno.h>

#include <machine/frameasm.h>
#include <machine/cputypes.h>

#define GET_CURPCB(reg)	\
	movl	CPUVAR(CURLWP),reg; \
	movl	L_PCB(reg),reg

/*
 * These are arranged so that the abnormal case is a forwards
 * conditional branch - which will be predicted not-taken by
 * both Intel and AMD processors.
 */
#define DEFERRED_SWITCH_CHECK \
	CHECK_DEFERRED_SWITCH			; \
	jnz	99f				; \
98:

#define DEFERRED_SWITCH_CALL \
99:						; \
	call	_C_LABEL(do_pmap_load)		; \
	jmp	98b

/*
 * The following primitives are to copy regions of memory.
 * Label must be before all copy functions.
 */
	.text
LABEL(x86_copyfunc_start)

/*
 * Handle deferred pmap switch.  We must re-enable preemption without
 * making a function call, so that the program counter is visible to
 * cpu_kpreempt_exit().  It can then know if it needs to restore the
 * pmap on returning, because a preemption occurred within one of the
 * copy functions.
 */
ENTRY(do_pmap_load)
	pushl	%ebp
	movl	%esp,%ebp
	pushl	%ebx
	movl	CPUVAR(CURLWP),%ebx
1:
	incl	L_NOPREEMPT(%ebx)
	call	_C_LABEL(pmap_load)
	decl	L_NOPREEMPT(%ebx)
	jnz	2f
	cmpl	$0,L_DOPREEMPT(%ebx)
	jz	2f
	pushl	$0
	call	_C_LABEL(kpreempt)
	addl	$4,%esp
2:
	cmpl	$0,CPUVAR(WANT_PMAPLOAD)
	jnz	1b
	popl	%ebx
	leave
	ret
END(do_pmap_load)

/*
 * void *return_address(unsigned int level);
 *
 * The return address if level == 0, the return address of the caller
 * `level' levels down the stack if level > 0.
 */
ENTRY(return_address)
	movl	%ebp,%eax	/* frame pointer -> %eax */
	movl	4(%esp),%ecx	/* level -> %ecx */
	movl	CPUVAR(CURLWP),%edx
	movl	L_PCB(%edx),%edx
	movl	$_C_LABEL(return_address_fault),PCB_ONFAULT(%edx)
	cmpl	$0,%ecx
	je	2f
1:
	movl	(%eax),%eax	/* next frame pointer */
	decl	%ecx
	jnz	1b
2:
	movl	0x4(%eax),%eax
	movl	$0,PCB_ONFAULT(%edx)
	ret
END(return_address)

/*
 * int kcopy(const void *from, void *to, size_t len);
 * Copy len bytes from and to kernel memory, and abort on fault.
 */
ENTRY(kcopy)
	pushl	%esi
	pushl	%edi
	movl	12(%esp),%esi
	movl	16(%esp),%edi
	movl	20(%esp),%ecx
.Lkcopy_start:
	movl	%edi,%eax
	subl	%esi,%eax
	cmpl	%ecx,%eax		/* overlapping? */
	movl	%ecx,%edx
	jb	1f
	/* nope, copy forward */
	shrl	$2,%ecx			/* copy by 32-bit words */
	rep
	movsl
	movl	%edx,%ecx
	andl	$3,%ecx			/* any bytes left? */
	jz	0f
	rep
	movsb
0:
	popl	%edi
	popl	%esi
	xorl	%eax,%eax
	ret

	ALIGN_TEXT
1:	addl	%ecx,%edi		/* copy backward */
	addl	%ecx,%esi
	std
	andl	$3,%ecx			/* any fractional bytes? */
	decl	%edi
	decl	%esi
	rep
	movsb
	movl	%edx,%ecx		/* copy remainder by 32-bit words */
	shrl	$2,%ecx
	subl	$3,%esi
	subl	$3,%edi
	rep
	movsl
	cld

.Lkcopy_end:
	popl	%edi
	popl	%esi
	xorl	%eax,%eax
	ret
END(kcopy)

/*****************************************************************************/

/*
 * The following primitives are used to copy data in and out of the user's
 * address space.
 */

/*
 * int copyout(const void *from, void *to, size_t len);
 * Copy len bytes into the user's address space.
 * see copyout(9)
 */
ENTRY(copyout)
	DEFERRED_SWITCH_CHECK
	pushl	%esi
	pushl	%edi
	movl	12(%esp),%esi	/* from */
	movl	16(%esp),%edi	/* to */
	movl	20(%esp),%eax	/* len */

	movl	%edi,%edx
	addl	%eax,%edx
	jc	_C_LABEL(copy_efault)
	cmpl	$VM_MAXUSER_ADDRESS,%edx
	ja	_C_LABEL(copy_efault)

	SMAP_DISABLE
.Lcopyout_start:
	movl	%eax,%ecx
	shrl	$2,%ecx
	rep
	movsl
	andl	$3,%eax
	jz	.Lcopyout_end
	movl	%eax,%ecx
	rep
	movsb
.Lcopyout_end:
	SMAP_ENABLE

	popl	%edi
	popl	%esi
	xorl	%eax,%eax
	ret
	DEFERRED_SWITCH_CALL
END(copyout)

/*
 * int copyin(const void *from, void *to, size_t len);
 * Copy len bytes from the user's address space.
 * see copyin(9)
 */
ENTRY(copyin)
	DEFERRED_SWITCH_CHECK
	pushl	%esi
	pushl	%edi
	movl	12(%esp),%esi	/* from */
	movl	16(%esp),%edi	/* to */
	movl	20(%esp),%eax	/* len */

	movl	%esi,%edx
	addl	%eax,%edx
	jc	_C_LABEL(copy_efault)
	cmpl	$VM_MAXUSER_ADDRESS,%edx
	ja	_C_LABEL(copy_efault)

	SMAP_DISABLE
.Lcopyin_start:
	movl	%eax,%ecx
	shrl	$2,%ecx
	rep
	movsl
	andl	$3,%eax
	jz	.Lcopyin_end
	movl	%eax,%ecx
	rep
	movsb
.Lcopyin_end:
	SMAP_ENABLE

	popl	%edi
	popl	%esi
	xorl	%eax,%eax
	ret
	DEFERRED_SWITCH_CALL
END(copyin)

ENTRY(copy_efault)
	movl	$EFAULT,%eax
	popl	%edi
	popl	%esi
	ret
END(copy_efault)

/*
 * kcopy_fault is used by kcopy and copy_fault is used by copyin/out.
 *
 * they're distinguished for lazy pmap switching.  see trap().
 */

ENTRY(kcopy_fault)
	cld
	popl	%edi
	popl	%esi
	ret
END(kcopy_fault)

ENTRY(copy_fault)
	SMAP_ENABLE
	popl	%edi
	popl	%esi
	ret
END(copy_fault)

ENTRY(return_address_fault)
	movl	$0,PCB_ONFAULT(%edx)
	movl	$0,%eax
	ret
END(return_address_fault)

/*
 * int copyoutstr(const void *from, void *to, size_t maxlen, size_t *lencopied);
 * Copy a NUL-terminated string, at most maxlen characters long, into the
 * user's address space.  Return the number of characters copied (including the
 * NUL) in *lencopied.  If the string is too long, return ENAMETOOLONG; else
 * return 0 or EFAULT.
 * see copyoutstr(9)
 */
ENTRY(copyoutstr)
	DEFERRED_SWITCH_CHECK
	pushl	%esi
	pushl	%edi
	movl	12(%esp),%esi	/* esi = from */
	movl	16(%esp),%edi	/* edi = to */
	movl	20(%esp),%edx	/* edx = maxlen */

	/*
	 * Get min(%edx, VM_MAXUSER_ADDRESS-%edi).
	 */
	movl	$VM_MAXUSER_ADDRESS,%eax
	subl	%edi,%eax
	jc	_C_LABEL(copystr_efault)
	cmpl	%edx,%eax
	jae	1f
	movl	%eax,%edx
	movl	%eax,20(%esp)
1:	incl	%edx

	SMAP_DISABLE
.Lcopyoutstr_start:
1:	decl	%edx
	jz	2f
	lodsb
	stosb
	testb	%al,%al
	jnz	1b
.Lcopyoutstr_end:
	SMAP_ENABLE

	/* Success -- 0 byte reached. */
	decl	%edx
	xorl	%eax,%eax
	jmp	copystr_return

2:	/* edx is zero -- return EFAULT or ENAMETOOLONG. */
	SMAP_ENABLE
	cmpl	$VM_MAXUSER_ADDRESS,%edi
	jae	_C_LABEL(copystr_efault)
	movl	$ENAMETOOLONG,%eax
	jmp	copystr_return
	DEFERRED_SWITCH_CALL
END(copyoutstr)

/*
 * int copyinstr(const void *from, void *to, size_t maxlen, size_t *lencopied);
 * Copy a NUL-terminated string, at most maxlen characters long, from the
 * user's address space.  Return the number of characters copied (including the
 * NUL) in *lencopied.  If the string is too long, return ENAMETOOLONG; else
 * return 0 or EFAULT.
 * see copyinstr(9)
 */
ENTRY(copyinstr)
	DEFERRED_SWITCH_CHECK
	pushl	%esi
	pushl	%edi
	movl	12(%esp),%esi		/* %esi = from */
	movl	16(%esp),%edi		/* %edi = to */
	movl	20(%esp),%edx		/* %edx = maxlen */

	/*
	 * Get min(%edx, VM_MAXUSER_ADDRESS-%esi).
	 */
	movl	$VM_MAXUSER_ADDRESS,%eax
	subl	%esi,%eax
	jc	_C_LABEL(copystr_efault)
	cmpl	%edx,%eax
	jae	1f
	movl	%eax,%edx
	movl	%eax,20(%esp)
1:	incl	%edx

	SMAP_DISABLE
.Lcopyinstr_start:
1:	decl	%edx
	jz	2f
	lodsb
	stosb
	testb	%al,%al
	jnz	1b
.Lcopyinstr_end:
	SMAP_ENABLE

	/* Success -- 0 byte reached. */
	decl	%edx
	xorl	%eax,%eax
	jmp	copystr_return

2:	/* edx is zero -- return EFAULT or ENAMETOOLONG. */
	SMAP_ENABLE
	cmpl	$VM_MAXUSER_ADDRESS,%esi
	jae	_C_LABEL(copystr_efault)
	movl	$ENAMETOOLONG,%eax
	jmp	copystr_return
	DEFERRED_SWITCH_CALL
END(copyinstr)

ENTRY(copystr_efault)
	movl	$EFAULT,%eax
	jmp	copystr_return
END(copystr_efault)

ENTRY(copystr_fault)
	SMAP_ENABLE
copystr_return:
	/* Set *lencopied and return %eax. */
	movl	20(%esp),%ecx
	subl	%edx,%ecx
	movl	24(%esp),%edx
	testl	%edx,%edx
	jz	8f
	movl	%ecx,(%edx)

8:	popl	%edi
	popl	%esi
	ret
END(copystr_fault)

/*
 * int copystr(const void *from, void *to, size_t maxlen, size_t *lencopied);
 * Copy a NUL-terminated string, at most maxlen characters long.  Return the
 * number of characters copied (including the NUL) in *lencopied.  If the
 * string is too long, return ENAMETOOLONG; else return 0.
 * see copystr(9)
 */
ENTRY(copystr)
	pushl	%esi
	pushl	%edi

	movl	12(%esp),%esi		/* esi = from */
	movl	16(%esp),%edi		/* edi = to */
	movl	20(%esp),%edx		/* edx = maxlen */
	incl	%edx

1:	decl	%edx
	jz	4f
	lodsb
	stosb
	testb	%al,%al
	jnz	1b

	/* Success -- 0 byte reached. */
	decl	%edx
	xorl	%eax,%eax
	jmp	6f

4:	/* edx is zero -- return ENAMETOOLONG. */
	movl	$ENAMETOOLONG,%eax

6:	/* Set *lencopied and return %eax. */
	movl	20(%esp),%ecx
	subl	%edx,%ecx
	movl	24(%esp),%edx
	testl	%edx,%edx
	jz	7f
	movl	%ecx,(%edx)

7:	popl	%edi
	popl	%esi
	ret
END(copystr)

/**************************************************************************/

#define	UFETCHSTORE_PROLOGUE(x)						\
	movl	4(%esp),%edx					;	\
	cmpl	$VM_MAXUSER_ADDRESS-x,%edx			;	\
	ja	_C_LABEL(ufetchstore_efault)

/* LINTSTUB: int _ufetch_8(const uint8_t *uaddr, uint8_t *valp); */
ENTRY(_ufetch_8)
	DEFERRED_SWITCH_CHECK
	UFETCHSTORE_PROLOGUE(1)

	SMAP_DISABLE
.L_ufetch_8_start:
	movb	(%edx),%al
.L_ufetch_8_end:
	SMAP_ENABLE

	movl	8(%esp),%edx
	movb	%al,(%edx)
	xorl	%eax,%eax
	ret
	DEFERRED_SWITCH_CALL
END(_ufetch_8)

/* LINTSTUB: int _ufetch_16(const uint16_t *uaddr, uint16_t *valp); */
ENTRY(_ufetch_16)
	DEFERRED_SWITCH_CHECK
	UFETCHSTORE_PROLOGUE(2)

	SMAP_DISABLE
.L_ufetch_16_start:
	movw	(%edx),%ax
.L_ufetch_16_end:
	SMAP_ENABLE

	movl	8(%esp),%edx
	movw	%ax,(%edx)
	xorl	%eax,%eax
	ret
	DEFERRED_SWITCH_CALL
END(_ufetch_16)

/* LINTSTUB: int _ufetch_32(const uint32_t *uaddr, uint32_t *valp); */
ENTRY(_ufetch_32)
	DEFERRED_SWITCH_CHECK
	UFETCHSTORE_PROLOGUE(4)

	SMAP_DISABLE
.L_ufetch_32_start:
	movl	(%edx),%eax
.L_ufetch_32_end:
	SMAP_ENABLE

	movl	8(%esp),%edx
	movl	%eax,(%edx)
	xorl	%eax,%eax
	ret
	DEFERRED_SWITCH_CALL
END(_ufetch_32)

/* LINTSTUB: int _ustore_8(uint8_t *uaddr, uint8_t val); */
ENTRY(_ustore_8)
	DEFERRED_SWITCH_CHECK
	UFETCHSTORE_PROLOGUE(1)
	movb	8(%esp),%al

	SMAP_DISABLE
.L_ustore_8_start:
	movb	%al,(%edx)
.L_ustore_8_end:
	SMAP_ENABLE

	xorl	%eax,%eax
	ret
	DEFERRED_SWITCH_CALL
END(_ustore_8)

/* LINTSTUB: int _ustore_16(uint16_t *uaddr, uint16_t val); */
ENTRY(_ustore_16)
	DEFERRED_SWITCH_CHECK
	UFETCHSTORE_PROLOGUE(2)
	movw	8(%esp),%ax

	SMAP_DISABLE
.L_ustore_16_start:
	movw	%ax,(%edx)
.L_ustore_16_end:
	SMAP_ENABLE

	xorl	%eax,%eax
	ret
	DEFERRED_SWITCH_CALL
END(_ustore_16)

/* LINTSTUB: int _ustore_32(uint32_t *uaddr, uint32_t val); */
ENTRY(_ustore_32)
	DEFERRED_SWITCH_CHECK
	UFETCHSTORE_PROLOGUE(4)
	movl	8(%esp),%eax

	SMAP_DISABLE
.L_ustore_32_start:
	movl	%eax,(%edx)
.L_ustore_32_end:
	SMAP_ENABLE

	xorl	%eax,%eax
	ret
	DEFERRED_SWITCH_CALL
END(_ustore_32)

ENTRY(ufetchstore_efault)
	movl	$EFAULT,%eax
	ret
END(ufetchstore_efault)

ENTRY(ufetchstore_fault)
	SMAP_ENABLE
	ret
END(ufetchstore_fault)

/**************************************************************************/

/*
 * Compare-and-swap the 32-bit integer in the user-space.
 *
 * int	_ucas_32(volatile uint32_t *uptr, uint32_t old, uint32_t new,
 *		 uint32_t *ret);
 */
ENTRY(_ucas_32)
	DEFERRED_SWITCH_CHECK
	movl	4(%esp),%edx
	movl	8(%esp),%eax
	movl	12(%esp),%ecx
	/* Fail if kernel-space */
	cmpl	$VM_MAXUSER_ADDRESS-4,%edx
	ja	_C_LABEL(ucas_efault)

	SMAP_DISABLE
.Lucas32_start:
	/* Perform the CAS */
	lock
	cmpxchgl %ecx,(%edx)
.Lucas32_end:
	SMAP_ENABLE

	/*
	 * Note: %eax is "old" value.
	 * Set the return values.
	 */
	movl	16(%esp),%edx
	movl	%eax,(%edx)
	xorl	%eax,%eax
	ret
	DEFERRED_SWITCH_CALL
END(_ucas_32)

ENTRY(ucas_efault)
	movl	$EFAULT,%eax
	ret
END(ucas_efault)

ENTRY(ucas_fault)
	SMAP_ENABLE
	ret
END(ucas_fault)

/*
 * copyin() optimised for bringing in syscall arguments.
 */
ENTRY(x86_copyargs)
	DEFERRED_SWITCH_CHECK
	pushl	%esi
	movl	8(%esp),%esi
	movl	12(%esp),%edx
	movl	16(%esp),%ecx

	/*
	 * In this function, we may copy more than the size given in the third
	 * argument. In order to make sure the real end of the destination
	 * buffer is not past the end of the user's address space, we don't
	 * check the third argument but rather the largest possible size, which
	 * is:
	 * 	(2 + SYS_MAXSYSARGS) * 4 = 10 * 4
	 */
	movl	%esi,%eax
	addl	$(10 * 4),%eax
	jc	_C_LABEL(x86_copyargs_efault)
	cmpl	$VM_MAXUSER_ADDRESS,%eax
	ja	_C_LABEL(x86_copyargs_efault)

	SMAP_DISABLE
.Lx86_copyargs_start:
	/* There are a maximum of 8 args + 2 for syscall indirect */
	cmp	$16,%ecx
	movl	(%esi),%eax
	movl	4(%esi),%ecx
	movl	%eax,(%edx)
	movl	%ecx,4(%edx)
	movl	8(%esi),%eax
	movl	12(%esi),%ecx
	movl	%eax,8(%edx)
	movl	%ecx,12(%edx)

	ja	2f		/* Optimise since most sycalls have <= 4 args */
	jmp	.Lx86_copyargs_end
2:

	movl	16(%esi),%eax
	movl	20(%esi),%ecx
	movl	%eax,16(%edx)
	movl	%ecx,20(%edx)
	movl	24(%esi),%eax
	movl	28(%esi),%ecx
	movl	%eax,24(%edx)
	movl	%ecx,28(%edx)
	movl	32(%esi),%eax
	movl	36(%esi),%ecx
	movl	%eax,32(%edx)
	movl	%ecx,36(%edx)
.Lx86_copyargs_end:
	SMAP_ENABLE

	popl	%esi
	xorl	%eax,%eax
	ret
	DEFERRED_SWITCH_CALL
END(x86_copyargs)

ENTRY(x86_copyargs_efault)
	movl	$EFAULT,%eax
	popl	%esi
	ret
END(x86_copyargs_efault)

ENTRY(x86_copyargs_fault)
	SMAP_ENABLE
	popl	%esi
	ret
END(x86_copyargs_fault)

/*
 * Label must be after all copy functions.
 */
LABEL(x86_copyfunc_end)

/*
 * Fault table of copy functions for trap().
 */
	.section ".rodata"
	.globl _C_LABEL(onfault_table)

_C_LABEL(onfault_table):
	.long .Lcopyin_start
	.long .Lcopyin_end
	.long _C_LABEL(copy_fault)

	.long .Lcopyout_start
	.long .Lcopyout_end
	.long _C_LABEL(copy_fault)

	.long .Lkcopy_start
	.long .Lkcopy_end
	.long _C_LABEL(kcopy_fault)

	.long .Lcopyoutstr_start
	.long .Lcopyoutstr_end
	.long _C_LABEL(copystr_fault)

	.long .Lcopyinstr_start
	.long .Lcopyinstr_end
	.long _C_LABEL(copystr_fault)

	.long .Lucas32_start
	.long .Lucas32_end
	.long _C_LABEL(ucas_fault)

	.long .L_ufetch_8_start
	.long .L_ufetch_8_end
	.long _C_LABEL(ufetchstore_fault)

	.long .L_ufetch_16_start
	.long .L_ufetch_16_end
	.long _C_LABEL(ufetchstore_fault)

	.long .L_ufetch_32_start
	.long .L_ufetch_32_end
	.long _C_LABEL(ufetchstore_fault)

	.long .L_ustore_8_start
	.long .L_ustore_8_end
	.long _C_LABEL(ufetchstore_fault)

	.long .L_ustore_16_start
	.long .L_ustore_16_end
	.long _C_LABEL(ufetchstore_fault)

	.long .L_ustore_32_start
	.long .L_ustore_32_end
	.long _C_LABEL(ufetchstore_fault)

	.long .Lx86_copyargs_start
	.long .Lx86_copyargs_end
	.long _C_LABEL(x86_copyargs_fault)

	.long 0	/* terminate */

	.text
