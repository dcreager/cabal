GHCFLAGS= --make -W -fno-warn-unused-matches -cpp
# later: -Wall
PREF=/usr/local
USER_FLAG =
GHCPKGFLAGS = 

# Comment out this line if your system doesn't have System.Posix.
ISPOSIX=-DHAVE_UNIX_PACKAGE

ifdef user
USER_FLAG = --user
GHCPKGFLAGS = -f ~/.ghc-packages
GHCFLAGS += -package-conf ~/.ghc-packages
endif

all: moduleTest

# build the library itself

setup::
	mkdir -p dist/tmp
	ghc $(GHCFLAGS) -odir dist/tmp -hidir dist/tmp Setup -o setup

Setup-nhc:
	hmake -nhc98 -package base -prelude Setup

config: setup
	./setup configure --ghc --prefix=$(PREF)

build: build-stamp
build-stamp: config
	./setup build

install: build-stamp
	./setup install $(USER_FLAG)

hugsbootstrap:
	rm -rf dist/tmp dist/hugs
	mkdir -p dist/tmp
	mkdir dist/hugs
	cp -r Distribution dist/tmp
	hugs-package dist/tmp dist/hugs
	cp Setup.lhs Setup.description dist/hugs

hugsinstall: hugsbootstrap
	cd dist/hugs && ./Setup.lhs configure --hugs
	cd dist/hugs && ./Setup.lhs build
	cd dist/hugs && ./Setup.lhs install

haddock: setup
	./setup haddock

clean: clean-cabal clean-hunit clean-test

clean-cabal:
	-rm -f Distribution/*.o Distribution/*.hi
	-rm -f Distribution/Simple/*.o Distribution/Simple/*.hi
	-rm -f Compat/*.o Compat/*.hi
	-rm -f library-infrastructure--darcs.tar.gz
	-rm -rf setup *.o *.hi moduleTest dist installed-pkg-config
	-rm -f build-stamp
	-rm -rf dist/hugs

clean-hunit:
	-rm -f hunit-stamp hunitInstall-stamp
	cd test/HUnit-1.0 && make clean

clean-test:
	cd test/A && make clean
	cd test/wash2hs && make clean

remove: remove-cabal remove-hunit
remove-cabal:
	-ghc-pkg $(GHCPKGFLAGS) -r Cabal
	-rm -rf $(PREF)/lib/Cabal-0.1
remove-hunit:
	-ghc-pkg $(GHCPKGFLAGS) -r HUnit
	-rm -rf $(PREF)/lib/HUnit-1.0

# dependencies (included):

hunit: hunit-stamp
hunit-stamp:
	cd test/HUnit-1.0 && make && ./setup configure --prefix=$(PREF) && ./setup build
	touch $@

hunitInstall: hunitInstall-stamp
hunitInstall-stamp: hunit-stamp
	cd test/HUnit-1.0 && ./setup install $(USER_FLAG)
	touch $@

# testing...

moduleTest:
	mkdir -p dist/debug
	ghc -main-is Distribution.ModuleTest.main $(GHCFLAGS) $(ISPOSIX) -DDEBUG -odir dist/debug -hidir dist/debug -idist/debug/:.:test/HUnit-1.0/src Distribution/ModuleTest -o moduleTest

tests: moduleTest clean
	cd test/A && make clean
	cd test/HUnit-1.0 && make clean
	cd test/A && make
	cd test/HUnit-1.0 && make

check:
	rm -f moduleTest
	make moduleTest
	./moduleTest

# distribution...

pushall:
	darcs push --all ijones@cvs.haskell.org:/home/darcs/cabal

pushdist: pushall dist
	scp /tmp/cabal-code.tgz ijones@www.haskell.org:~/cabal/cabal-code.tgz
#	rm -f /tmp/cabal-code.tgz

dist: haddock
	darcs dist
	mv Cabal.tar.gz /tmp
	cd /tmp && tar -zxvf Cabal.tar.gz
	mkdir -p /tmp/cabal/doc
	cp -r dist/doc/html /tmp/cabal/doc/API
	cd ~/usr/doc/haskell/haskell-report/packages && docbook2html -o /tmp/pkg-spec-html pkg-spec.sgml && docbook2pdf pkg-spec.sgml -o /tmp
	cp -r /tmp/pkg-spec{-html,.pdf} /tmp/cabal/doc

	cd /tmp && tar -zcvf cabal-code.tgz cabal
	rm -f /tmp/Cabal.tar.gz
	rm -rf /tmp/cabal