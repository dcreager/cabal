-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.PreProcess
-- 
-- Maintainer  :  Isaac Jones <ijones@syntaxpolice.org>
-- Stability   :  alpha
-- Portability :  GHC, Hugs
--
{- Copyright (c) 2003-2004, Isaac Jones, Malcolm Wallace
All rights reserved.

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

module Distribution.PreProcess (preprocessSources, knownSuffixHandlers,
                                ppSuffixes, PPSuffixHandler, PreProcessor,
                                removePreprocessed, removePreprocessedPackage)
    where

import Distribution.PreProcess.Unlit(unlit)
import Distribution.PackageDescription (setupMessage, PackageDescription(..),
                                        BuildInfo(..), Executable(..),
					biModules, withLib)
import Distribution.Setup (CompilerFlavor(..), compilerFlavor)
import Distribution.Simple.Configure (LocalBuildInfo(..))
import Distribution.Simple.Utils (rawSystemPath, moduleToFilePath, die)
import Control.Monad (when)
import Data.Maybe (fromMaybe)
import System.Exit (ExitCode(..))
import System.Directory (removeFile)
import Distribution.Compat.FilePath
	(splitFileExt, joinFileName, joinFileExt)

-- |A preprocessor must fulfill this basic interface.  It can be an
-- external program, or just a function.
type PreProcessor = FilePath  -- ^Location of the source file in need of preprocessing
                  -> FilePath -- ^Output filename
                  -> IO ExitCode


-- |A preprocessor for turning non-Haskell files with the given extension
-- into plain Haskell source files.
type PPSuffixHandler
    = (String, PackageDescription -> LocalBuildInfo -> PreProcessor)

-- |Apply preprocessors to the sources from 'hsSourceDir', to obtain
-- a Haskell source file for each module.
preprocessSources :: PackageDescription 
		  -> LocalBuildInfo 
                  -> [PPSuffixHandler]  -- ^ preprocessors to try
		  -> IO ()

preprocessSources pkg_descr lbi handlers = do
    setupMessage "Preprocessing" pkg_descr
    foreachBuildInfo pkg_descr $ \ bi ->
	sequence_ [preprocessModule (hsSourceDir bi) mod localHandlers |
			    mod <- biModules bi] -- FIX: output errors?
  where hc = compilerFlavor (compiler lbi)
	builtinSuffixes
	  | hc == NHC = ["hs", "lhs", "gc"]
	  | otherwise = ["hs", "lhs"]
	localHandlers = [(ext, Nothing) | ext <- builtinSuffixes] ++
			[(ext, Just (h pkg_descr lbi)) | (ext, h) <- handlers]

-- |Find the first extension of the file that exists, and preprocess it
-- if required.
preprocessModule
    :: FilePath				-- ^source directory
    -> String				-- ^module name
    -> [(String, Maybe PreProcessor)]	-- ^possible preprocessors
    -> IO ExitCode
preprocessModule searchLoc mod handlers = do
    srcFiles <- moduleToFilePath searchLoc mod (map fst handlers)
    case srcFiles of
	[] -> die ("can't find source for " ++ mod)
	(srcFile:_) -> do
	    let (srcStem, ext) = splitFileExt srcFile
	    case fromMaybe (error "Internal error in preProcess module: Just expected")
                     (lookup ext handlers) of -- FIX: can't fail?
		Nothing -> return ExitSuccess
		Just pp -> pp srcFile (srcStem `joinFileExt` "hs")

removePreprocessedPackage :: PackageDescription
                          -> FilePath -- ^root of source tree (where to look for hsSources)
                          -> [String] -- ^suffixes
                          -> IO ()
removePreprocessedPackage pkg_descr r suff
    = foreachBuildInfo pkg_descr $ \ bi ->
	removePreprocessed (r `joinFileName` hsSourceDir bi) (biModules bi) suff

-- |Remove the preprocessed .hs files. (do we need to get some .lhs files too?)
removePreprocessed :: FilePath -- ^search Location
                   -> [String] -- ^Modules
                   -> [String] -- ^suffixes
                   -> IO ()
removePreprocessed searchLoc mods suffixesIn
    = mapM_ removePreprocessedModule mods
  where removePreprocessedModule m = do
	    -- collect related files
	    fs <- moduleToFilePath searchLoc m otherSuffixes
	    -- does M.hs also exist?
	    hs <- moduleToFilePath searchLoc m ["hs"]
	    when (not (null fs)) (mapM_ removeFile hs)
	otherSuffixes = filter (/= "hs") suffixesIn

-- | Perform the action on each 'BuildInfo' in the package description.
foreachBuildInfo :: PackageDescription -> (BuildInfo -> IO a) -> IO ()
foreachBuildInfo pkg_descr action = do
    withLib pkg_descr (\ bi -> action bi >> return ())
    mapM_ (action . buildInfo) (executables pkg_descr)

-- ------------------------------------------------------------
-- * known preprocessors
-- ------------------------------------------------------------

ppCpp, ppGreenCard, ppC2hs :: PreProcessor

ppCpp inFile outFile
    = rawSystemPath "cpphs" ["-O" ++ outFile, inFile]
ppGreenCard inFile outFile
    = rawSystemPath "green-card" ["-tffi", "-o" ++ outFile, inFile]
ppC2hs inFile outFile
    = rawSystemPath "c2hs" ["-o " ++ outFile, inFile]

-- This one is useful for preprocessors that can't handle literate source.
-- We also need a way to chain preprocessors.
ppUnlit :: PreProcessor
ppUnlit inFile outFile = do
    contents <- readFile inFile
    writeFile outFile (unlit inFile contents)
    return ExitSuccess

-- FIX (non-GHC): This uses hsc2hs as supplied with GHC, but this may
-- not be present, and if present will pass GHC-specific cpp defines to
-- the C compiler.
ppHsc2hs :: PackageDescription -> LocalBuildInfo -> PreProcessor
ppHsc2hs pkg_descr lbi
    = standardPP "hsc2hs" (hcFlags hc ++ ccOptions pkg_descr)
  where hc = compilerFlavor (compiler lbi)
	hcFlags NHC = ["-D__NHC__"]
	hcFlags Hugs = ["-D__HUGS__"]
	hcFlags _ = []

ppHappy :: PackageDescription -> LocalBuildInfo -> PreProcessor
ppHappy _ lbi
    = standardPP "happy" (hcFlags hc)
  where hc = compilerFlavor (compiler lbi)
	hcFlags GHC = ["-agc"]
	hcFlags _ = []

ppTestHandler :: FilePath -- ^InFile
              -> FilePath -- ^OutFile
              -> IO ExitCode
ppTestHandler inFile outFile
    = do stuff <- readFile inFile
         writeFile outFile ("-- this file has been preprocessed as a test\n\n" ++ stuff)
         return ExitSuccess

standardPP :: String -> [String] -> PreProcessor
standardPP eName args inFile outFile
    = rawSystemPath eName (args ++ ["-o" ++ outFile, inFile])

-- |Convenience function; get the suffixes of these preprocessors.
ppSuffixes :: [ PPSuffixHandler ] -> [String]
ppSuffixes = map fst

knownSuffixHandlers :: [ PPSuffixHandler ]
knownSuffixHandlers =
  [ ("gc",     \ _ _ -> ppGreenCard)
  , ("chs",    \ _ _ -> ppC2hs)
  , ("hsc",    ppHsc2hs)
  , ("y",      ppHappy)
  , ("ly",     ppHappy)
  , ("cpphs",  \ _ _ -> ppCpp)
  , ("testSuffix", \ _ _ -> ppTestHandler)
  ]
