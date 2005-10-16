{-# OPTIONS -fffi #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.LocalBuildInfo
-- Copyright   :  Isaac Jones 2003-2004
-- 
-- Maintainer  :  Isaac Jones <ijones@syntaxpolice.org>
-- Stability   :  alpha
-- Portability :  portable
--
-- Definition of the LocalBuildInfo data type.

{- All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of Isaac Jones nor the names of other
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. -}

module Distribution.Simple.LocalBuildInfo ( 
	LocalBuildInfo(..),
	default_prefix,
	default_bindir,
	default_libdir,
	default_libsubdir,
	default_libexecdir,
	default_datadir,
	default_datasubdir,
	mkLibDir, mkBinDir, mkLibexecDir, mkDataDir, mkProgDir,
	substDir,
  ) where

import Distribution.Package (PackageIdentifier)
import Distribution.Compiler (Compiler)

-- |Data cached after configuration step.
data LocalBuildInfo = LocalBuildInfo {
  	prefix	      :: FilePath,
		-- ^ The installation directory (eg. @/usr/local@, or
		-- @C:/Program Files/foo-1.2@ on Windows.
	bindir        :: FilePath,
		-- ^ The bin directory
	libdir        :: FilePath,
		-- ^ The lib directory
	libsubdir     :: FilePath,
		-- ^ Subdirectory of libdir into which libraries are installed
	libexecdir    :: FilePath,
		-- ^ The lib directory
	datadir       :: FilePath,
		-- ^ The data directory
	datasubdir    :: FilePath,
		-- ^ Subdirectory of datadir into which data files are installed
	compiler      :: Compiler,
		-- ^ The compiler we're building with
	buildDir      :: FilePath,
		-- ^ Where to put the result of building.
	packageDeps   :: [PackageIdentifier],
		-- ^ Which packages we depend on, /exactly/.
		-- The 'Distribution.PackageDescription.PackageDescription'
		-- specifies a set of build dependencies
		-- that must be satisfied in terms of version ranges.  This
		-- field fixes those dependencies to the specific versions
		-- available on this machine for this compiler.
        withPrograms  :: ProgramConfiguration, -- location and args for all programs
        withHappy     :: Maybe FilePath, -- ^Might be the location of the Happy executable.
        withAlex      :: Maybe FilePath, -- ^Might be the location of the Alex executable.
        withHsc2hs    :: Maybe FilePath, -- ^Might be the location of the Hsc2hs executable.
        withC2hs      :: Maybe FilePath, -- ^Might be the location of the C2hs executable.
        withCpphs     :: Maybe FilePath, -- ^Might be the location of the Cpphs executable.
        withGreencard :: Maybe FilePath, -- ^Might be the location of the GreenCard executable.
        withProfLib   :: Bool,
        withProfExe   :: Bool,
	withGHCiLib   :: Bool
  } deriving (Read, Show)

-- -----------------------------------------------------------------------------
-- Default directories

{-
The defaults are as follows:

Windows:
	prefix	   = C:\Program Files
	bindir     = $prefix\$pkgid
	libdir     = $prefix\Haskell
	libsubdir  = $pkgid\$compiler
	datadir    = $prefix			(for an executable)
	           = $prefix\Common Files	(for a library)
	datasubdir = $pkgid
	libexecdir = $prefix\$pkgid

Unix:
	prefix	   = /usr/local
	bindir	   = $prefix/bin
	libdir	   = $prefix/lib/$pkgid/$compiler
	libsubdir  = $pkgid/$compiler
	datadir	   = $prefix/share/$pkgid
	datasubdir = $pkgid
	libexecdir = $prefix/libexec
-}

default_prefix :: IO String
#if mingw32_HOST_OS || mingw32_TARGET_OS
# if __HUGS__
default_prefix = return "C:\\Program Files"
# else
default_prefix = getProgramFilesDir
# endif
#else
default_prefix = return "/usr/local"
#endif

#if mingw32_HOST_OS || mingw32_TARGET_OS
getProgramFilesDir = do
  m <- shGetFolderPath csidl_PROGRAM_FILES
  return (fromMaybe "C:\\Program Files" m)

getCommonFilesDir = do
  m <- shGetFolderPath csidl_PROGRAM_FILES_COMMON
  case m of
   Nothing -> getProgramFilesDir
   Just s  -> return s

shGetFolderPath id =
  allocaBytes long_path_size $ \pPath -> do
     r <- c_SHGetFolderPath nullPtr id nullPtr 0 pPath
     if (r /= 0) 
	then return Nothing
	else do s <- peekCString pPath; return (Just s)
  where
    long_path_size      = 1024

csidl_PROGRAM_FILES = 0x0026
csidl_PROGRAM_FILES_COMMON = 0x002b

foreign import stdcall unsafe "shlobj.h SHGetFolderPathA" 
            c_SHGetFolderPath :: Ptr () 
                              -> CInt 
                              -> Ptr () 
                              -> CInt 
                              -> CString 
                              -> IO CInt
#endif

default_bindir = "$prefix" `joinFileName`
#if mingw32_HOST_OS || mingw32_TARGET_OS
	"$pkgid"
#else
	"bin"
#endif

default_libdir hc = "$prefix" `joinFileName`
#if mingw32_HOST_OS || mingw32_TARGET_OS
                 "Haskell"
#else
                 "lib"
#endif

default_libsubdir hc =
  case compilerFlavor hc of
	Hugs -> "hugs" `joinFileName` "packages" `joinFileName` "$pkg"
	_    -> "$pkgid" `joinFileName` "$compiler"

default_libexecdir = "$prefix" `joinFileName`
#if mingw32_HOST_OS || mingw32_TARGET_OS
	"$pkgid"
#else
	"libexec"
#endif

default_datadir :: PackageDescription -> IO FilePath
default_datadir pkg_descr
#if mingw32_HOST_OS || mingw32_TARGET_OS
	| hasLibs pkg_descr = getCommonFilesDir
	| otherwise = return "$prefix"
#else
	= return  ("$prefix" `joinFileName` "share")
#endif

default_datasubdir = "$pkgid"


mkBinDir :: PackageDescription -> LocalBuildInfo -> CopyDest -> FilePath
mkBinDir pkg_descr lbi0 copydest = 
  prepend copydest $
  substDir pkg_descr lbi (bindir lbi)
 where
  lbi = case copydest of 
	 CopyPrefix d -> lbi0{prefix=d}
         _otherwise   -> lbi0

mkLibDir :: PackageDescription -> LocalBuildInfo -> CopyDest -> FilePath
mkLibDir pkg_descr lbi0 copydest = 
  prepend copydest $
  substDir pkg_descr lbi (libdir lbi) `joinFileName`
  substDir pkg_descr lbi (libsubdir lbi)
 where
  lbi = case copydest of 
	 CopyPrefix d -> lbi0{prefix=d}
         _otherwise   -> lbi0

mkLibexecDir :: PackageDescription -> LocalBuildInfo -> CopyDest -> FilePath
mkLibexecDir pkg_descr lbi0 copydest = 
  prepend copydest $
  substDir pkg_descr lbi (libexecdir lbi)
 where
  lbi = case copydest of 
	 CopyPrefix d -> lbi0{prefix=d}
         _otherwise   -> lbi0

mkDataDir :: PackageDescription -> LocalBuildInfo -> CopyDest -> FilePath
mkDataDir pkg_descr lbi0 copydest = 
  prepend copydest $
  substDir pkg_descr lbi (datadir lbi) `joinFileName`
  substDir pkg_descr lbi (datasubdir lbi)
 where
  lbi = case copydest of 
	 CopyPrefix d -> lbi0{prefix=d}
         _otherwise   -> lbi0

-- | Directory for program modules (Hugs only).
mkProgDir :: PackageDescription -> LocalBuildInfo -> CopyDest -> FilePath
mkProgDir pkg_descr lbi0 copydest = 
  prepend copydest $
  substDir pkg_descr lbi (libdir lbi) `joinFileName`
  "hugs" `joinFileName` "programs"
 where
  lbi = case copydest of 
	 CopyPrefix d -> lbi0{prefix=d}
         _otherwise   -> lbi0

prepend (CopyTo p) q = p `joinFileName` dropAbsolutePrefix q
prepend _          q = q

substDir :: PackageDescription -> LocalBuildInfo -> String -> String
substDir pkg_descr lbi s = loop s
 where
  loop "" = ""
  loop ('$':'p':'r':'e':'f':'i':'x':s) 
	= prefix lbi ++ loop s
  loop ('$':'c':'o':'m':'p':'i':'l':'e':'r':s) 
	= showCompilerId (compiler lbi) ++ loop s
  loop ('$':'p':'k':'g':'i':'d':s) 
	= showPackageId (package pkg_descr) ++ loop s
  loop ('$':'p':'k':'g':s) 
	= pkgName (package pkg_descr) ++ loop s
  loop ('$':'v':'e':'r':'s':'i':'o':'n':s) 
	= show (pkgVersion (package pkg_descr)) ++ loop s
  loop ('$':'$':s) = '$' : loop s
  loop (c:s) = c : loop s
