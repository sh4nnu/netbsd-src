# $NetBSD: Makefile,v 1.9 2019/06/01 06:59:17 kre Exp $
#

.include <bsd.own.mk>

TESTSDIR=	${TESTSBASE}/net/if

TESTS_C=	t_compat
.for name in ifconf ifconfig
TESTS_SH+=		t_${name}
TESTS_SH_SRC_t_${name}=	../net_common.sh t_${name}.sh
.endfor

PROGS=		ifconf
MAN.ifconf=	# empty
BINDIR.ifconf=	${TESTSDIR}

LDADD.t_compat=		-lrumpnet_shmif -lrumpnet_netinet -lrumpnet_net -lrumpnet -lrump
LDADD.t_compat+=	-lrumpuser -lrump -lrumpvfs -lpthread

.include <bsd.test.mk>
