{-# OPTIONS -cpp #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple
-- Copyright   :  Isaac Jones 2003-2005
-- 
-- Maintainer  :  Isaac Jones <ijones@syntaxpolice.org>
-- Stability   :  alpha
-- Portability :  portable
--
-- Explanation: Simple build system; basically the interface for
-- Distribution.Simple.\* modules.  When given the parsed command-line
-- args and package information, is able to perform basic commands
-- like configure, build, install, register, etc.
--
-- This module isn't called \"Simple\" because it's simple.  Far from
-- it.  It's called \"Simple\" because it does complicated things to
-- simple software.

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

module Distribution.Simple (
	module Distribution.Package,
	module Distribution.Version,
	module Distribution.License,
	module Distribution.Simple.Compiler,
	module Language.Haskell.Extension,
        -- * Simple interface
	defaultMain, defaultMainNoRead, defaultMainArgs,
        -- * Customization
        UserHooks(..), Args,
        defaultMainWithHooks, defaultMainWithHooksArgs,
	-- ** Standard sets of hooks
        simpleUserHooks,
        autoconfUserHooks,
        defaultUserHooks, emptyUserHooks,
        -- ** Utils
        defaultHookedPackageDesc
#ifdef DEBUG        
        ,simpleHunitTests
#endif
  ) where

-- local
import Distribution.Simple.Compiler hiding (Flag)
import Distribution.Simple.UserHooks
import Distribution.Package --must not specify imports, since we're exporting moule.
import Distribution.PackageDescription
import Distribution.Simple.Program
         ( ProgramConfiguration, defaultProgramConfiguration, addKnownProgram
         , userSpecifyArgs, pfesetupProgram, rawSystemProgramConf )
import Distribution.Simple.PreProcess (knownSuffixHandlers,
                                removePreprocessedPackage,
                                preprocessSources, PPSuffixHandler)
import Distribution.Simple.Setup
import Distribution.Simple.Command

import Distribution.Simple.Build	( build, makefile )
import Distribution.Simple.SrcDist	( sdist )
import Distribution.Simple.Register	( register, unregister,
                                          writeInstalledConfig,
                                          removeRegScripts
                                        )

import Distribution.Simple.Configure(getPersistBuildConfig, 
                                     maybeGetPersistBuildConfig,
                                     checkPersistBuildConfig,
                                     configure, writePersistBuildConfig)

import Distribution.Simple.LocalBuildInfo ( LocalBuildInfo(..), distPref, srcPref)
import Distribution.Simple.Install (install)
import Distribution.Simple.Haddock (haddock, hscolour)
import Distribution.Simple.Utils
         (die, notice, info, warn, currentDir, moduleToFilePath,
          defaultPackageDesc, defaultHookedPackageDesc,
          rawSystemPathExit, rawSystemExit)
import Distribution.Verbosity
import Language.Haskell.Extension
-- Base
import System.Environment(getArgs,getProgName)
import System.Directory(removeFile, doesFileExist, doesDirectoryExist)

import Distribution.License
import Control.Monad   (when, unless)
import Data.List       (intersperse, unionBy)
import System.IO.Error (catch)

import Distribution.Compat.Directory(removeDirectoryRecursive)
import System.FilePath((</>))

#ifdef DEBUG
import Test.HUnit (Test)
import Distribution.Version hiding (hunitTests)
#else
import Distribution.Version
#endif

import System.Exit

-- | A simple implementation of @main@ for a Cabal setup script.
-- It reads the package description file using IO, and performs the
-- action specified on the command line.
defaultMain :: IO ()
defaultMain = getArgs >>= defaultMainHelper simpleUserHooks

-- | A version of 'defaultMain' that is passed the command line
-- arguments, rather than getting them from the environment.
defaultMainArgs :: [String] -> IO ()
defaultMainArgs = defaultMainHelper simpleUserHooks

-- | A customizable version of 'defaultMain'.
defaultMainWithHooks :: UserHooks -> IO ()
defaultMainWithHooks hooks = getArgs >>= defaultMainHelper hooks

-- | A customizable version of 'defaultMain' that also takes the command
-- line arguments.
defaultMainWithHooksArgs :: UserHooks -> [String] -> IO ()
defaultMainWithHooksArgs = defaultMainHelper

-- | Like 'defaultMain', but accepts the package description as input
-- rather than using IO to read it.
defaultMainNoRead :: PackageDescription -> IO ()
defaultMainNoRead pkg_descr =
  getArgs >>=
  defaultMainHelper simpleUserHooks { readDesc = return (Just pkg_descr) }

defaultMainHelper :: UserHooks -> Args -> IO ()
defaultMainHelper hooks args =
  case commandsRun globalCommand commands args of
    CommandHelp   help                 -> printHelp help
    CommandList   opts                 -> printOptionsList opts
    CommandErrors errs                 -> printErrors errs
    CommandReadyToGo (flags, commandParse)  ->
      case commandParse of
        _ | fromFlag (globalVersion flags)        -> printVersion
          | fromFlag (globalNumericVersion flags) -> printNumericVersion
        CommandHelp     help           -> printHelp help
        CommandList     opts           -> printOptionsList opts
        CommandErrors   errs           -> printErrors errs
        CommandReadyToGo action        -> action

  where
    printHelp help = getProgName >>= putStr . help
    printOptionsList = putStr . unlines
    printErrors errs = do
      putStr (concat (intersperse "\n" errs))
      exitWith (ExitFailure 1)
    printNumericVersion = putStrLn $ showVersion cabalVersion
    printVersion        = putStrLn $ "Cabal library version "
                                  ++ showVersion cabalVersion

    progs = allPrograms hooks
    commands =
      [configureCommand progs `commandAddAction` configureAction    hooks
      ,buildCommand     progs `commandAddAction` buildAction        hooks
      ,installCommand         `commandAddAction` installAction      hooks
      ,copyCommand            `commandAddAction` copyAction         hooks
      ,haddockCommand         `commandAddAction` haddockAction      hooks
      ,cleanCommand           `commandAddAction` cleanAction        hooks
      ,sdistCommand           `commandAddAction` sdistAction        hooks
      ,hscolourCommand        `commandAddAction` hscolourAction     hooks
      ,registerCommand        `commandAddAction` registerAction     hooks
      ,unregisterCommand      `commandAddAction` unregisterAction   hooks
      ,testCommand            `commandAddAction` testAction         hooks
      ,programaticaCommand    `commandAddAction` programaticaAction hooks
      ,makefileCommand        `commandAddAction` makefileAction     hooks
      ]

-- | Combine the programs in the given hooks with the programs built
-- into cabal.
allPrograms :: UserHooks
            -> ProgramConfiguration -- combine defaults w/ user programs
allPrograms h = foldl (flip addKnownProgram) 
                      defaultProgramConfiguration
                      (hookedPrograms h)

-- | Combine the preprocessors in the given hooks with the
-- preprocessors built into cabal.
allSuffixHandlers :: UserHooks
                  -> [PPSuffixHandler]
allSuffixHandlers hooks
    = overridesPP (hookedPreProcessors hooks) knownSuffixHandlers
    where
      overridesPP :: [PPSuffixHandler] -> [PPSuffixHandler] -> [PPSuffixHandler]
      overridesPP = unionBy (\x y -> fst x == fst y)

configureAction :: UserHooks -> ConfigFlags -> Args -> IO ()
configureAction hooks flags args = do
                pbi <- preConf hooks args flags

                (mb_pd_file, pkg_descr0) <- confPkgDescr

                --    get_pkg_descr (configVerbose flags')
                --let pkg_descr = updatePackageDescription pbi pkg_descr0
                let epkg_descr = (pkg_descr0, pbi)

                --(warns, ers) <- sanityCheckPackage pkg_descr
                --errorOut (configVerbose flags') warns ers

		localbuildinfo0 <- confHook hooks epkg_descr flags

                -- remember the .cabal filename if we know it
                let localbuildinfo = localbuildinfo0{ pkgDescrFile = mb_pd_file }
                writePersistBuildConfig localbuildinfo
                
		let pkg_descr = localPkgDescr localbuildinfo
                postConf hooks args flags pkg_descr localbuildinfo
              where
                verbosity = fromFlag (configVerbose flags)
                confPkgDescr :: IO (Maybe FilePath,
                                    Either GenericPackageDescription
                                           PackageDescription)
                confPkgDescr = do
                  mdescr <- readDesc hooks
                  case mdescr of
                    Just descr -> return (Nothing, Right descr)
                    Nothing -> do
                      pdfile <- defaultPackageDesc verbosity
                      ppd <- readPackageDescription verbosity pdfile
                      return (Just pdfile, Left ppd)

buildAction :: UserHooks -> BuildFlags -> Args -> IO ()
buildAction hooks flags args = do
                lbi <- getBuildConfigIfUpToDate
                let progs = foldr (uncurry userSpecifyArgs)
                                  (withPrograms lbi) (buildProgramArgs flags)
                hookedAction preBuild buildHook postBuild
                             (return lbi { withPrograms = progs })
                             hooks flags args

makefileAction :: UserHooks -> MakefileFlags -> Args -> IO ()
makefileAction = hookedAction preMakefile makefileHook postMakefile
                              getBuildConfigIfUpToDate

hscolourAction :: UserHooks -> HscolourFlags -> Args -> IO ()
hscolourAction = hookedAction preHscolour hscolourHook postHscolour
                              getBuildConfigIfUpToDate
        
haddockAction :: UserHooks -> HaddockFlags -> Args -> IO ()
haddockAction = hookedAction preHaddock haddockHook postHaddock
                             getBuildConfigIfUpToDate

programaticaAction :: UserHooks -> PFEFlags -> Args -> IO ()
programaticaAction = hookedAction prePFE pfeHook postPFE
                                  getBuildConfigIfUpToDate

cleanAction :: UserHooks -> CleanFlags -> Args -> IO ()
cleanAction hooks flags args = do
                pbi <- preClean hooks args flags

                mlbi <- maybeGetPersistBuildConfig
                pdfile <- defaultPackageDesc verbosity
                ppd <- readPackageDescription verbosity pdfile
                let pkg_descr0 = flattenPackageDescription ppd
                let pkg_descr = updatePackageDescription pbi pkg_descr0

                cleanHook hooks pkg_descr mlbi hooks flags
                postClean hooks args flags pkg_descr mlbi
  where verbosity = fromFlag (cleanVerbose flags)

copyAction :: UserHooks -> CopyFlags -> Args -> IO ()
copyAction = hookedAction preCopy copyHook postCopy
                          getBuildConfigIfUpToDate

installAction :: UserHooks -> InstallFlags -> Args -> IO ()
installAction = hookedAction preInst instHook postInst
                             getBuildConfigIfUpToDate

sdistAction :: UserHooks -> SDistFlags -> Args -> IO ()
sdistAction hooks flags args = do
                pbi <- preSDist hooks args flags

                mlbi <- maybeGetPersistBuildConfig
                pdfile <- defaultPackageDesc verbosity
                ppd <- readPackageDescription verbosity pdfile
                let pkg_descr0 = flattenPackageDescription ppd
                let pkg_descr = updatePackageDescription pbi pkg_descr0

                sDistHook hooks pkg_descr mlbi hooks flags
                postSDist hooks args flags pkg_descr mlbi
  where verbosity = fromFlag (sDistVerbose flags)

testAction :: UserHooks -> () -> Args -> IO ()
testAction hooks _flags args = do
                localbuildinfo <- getBuildConfigIfUpToDate
                let pkg_descr = localPkgDescr localbuildinfo
                runTests hooks args False pkg_descr localbuildinfo

registerAction :: UserHooks -> RegisterFlags -> Args -> IO ()
registerAction = hookedAction preReg regHook postReg
                              getBuildConfigIfUpToDate

unregisterAction :: UserHooks -> RegisterFlags -> Args -> IO ()
unregisterAction = hookedAction preUnreg unregHook postUnreg
                                getBuildConfigIfUpToDate

hookedAction :: (UserHooks -> Args -> flags -> IO HookedBuildInfo)
        -> (UserHooks -> PackageDescription -> LocalBuildInfo
                      -> UserHooks -> flags -> IO ())
        -> (UserHooks -> Args -> flags -> PackageDescription
                      -> LocalBuildInfo -> IO ())
        -> IO LocalBuildInfo
        -> UserHooks -> flags -> Args -> IO ()
hookedAction pre_hook cmd_hook post_hook get_build_config hooks flags args = do
   pbi <- pre_hook hooks args flags
   localbuildinfo <- get_build_config
   let pkg_descr0 = localPkgDescr localbuildinfo
   --pkg_descr0 <- get_pkg_descr (get_verbose flags)
   let pkg_descr = updatePackageDescription pbi pkg_descr0
   -- XXX: should we write the modified package descr back to the
   -- localbuildinfo?
   cmd_hook hooks pkg_descr localbuildinfo hooks flags
   post_hook hooks args flags pkg_descr localbuildinfo


--TODO: where to put this? it's duplicated in .Haddock too
getModulePaths :: LocalBuildInfo -> BuildInfo -> [String] -> IO [FilePath]
getModulePaths lbi bi =
   fmap concat .
      mapM (flip (moduleToFilePath (buildDir lbi : hsSourceDirs bi)) ["hs", "lhs"])

getBuildConfigIfUpToDate :: IO LocalBuildInfo
getBuildConfigIfUpToDate = do
   lbi <- getPersistBuildConfig
   case pkgDescrFile lbi of
     Nothing -> return ()
     Just pkg_descr_file -> checkPersistBuildConfig pkg_descr_file
   return lbi

-- --------------------------------------------------------------------------
-- Programmatica support

pfe :: PackageDescription -> [PPSuffixHandler] -> PFEFlags -> IO ()
pfe pkg_descr pps flags = do
    unless (hasLibs pkg_descr) $
        die "no libraries found in this project"
    withLib pkg_descr () $ \lib -> do
        lbi <- getPersistBuildConfig
        let bi = libBuildInfo lib
        let mods = exposedModules lib ++ otherModules (libBuildInfo lib)
        preprocessSources pkg_descr lbi False verbosity pps
        inFiles <- getModulePaths lbi bi mods
        let verbFlags = if verbosity >= deafening then ["-v"] else []
        rawSystemProgramConf verbosity pfesetupProgram (withPrograms lbi)
                             ("noplogic" : "cpp" : verbFlags ++ inFiles)
  where verbosity = fromFlag (pfeVerbose flags)

-- --------------------------------------------------------------------------
-- Cleaning

-- | Perform an IO action, catching any IO exceptions and printing an error
--   if one occurs.
chattyTry :: String  -- ^ a description of the action we were attempting
          -> IO ()  -- ^ the action itself
          -> IO ()
chattyTry desc action = do
  catch action
        (\e -> putStrLn $ "Error while " ++ desc ++ ": " ++ show e)

clean :: PackageDescription -> Maybe LocalBuildInfo -> CleanFlags -> IO ()
clean pkg_descr maybeLbi flags = do
    notice verbosity "cleaning..."

    maybeConfig <- if fromFlag (cleanSaveConf flags)
                     then maybeGetPersistBuildConfig
                     else return Nothing

    -- remove the whole dist/ directory rather than tracking exactly what files
    -- we created in there.
    chattyTry "removing dist/" $ removeDirectoryRecursive distPref

    -- these live in the top level dir so must be removed separately
    removeRegScripts

    -- Any extra files the user wants to remove
    mapM_ removeFileOrDirectory (extraTmpFiles pkg_descr)

    -- FIXME: put all JHC's generated files under dist/ so they get cleaned
    case maybeLbi of
      Nothing  -> return ()
      Just lbi -> do
        case compilerFlavor (compiler lbi) of
          JHC -> cleanJHCExtras lbi
          _   -> return ()

    -- If the user wanted to save the config, write it back
    maybe (return ()) writePersistBuildConfig maybeConfig

  where
        -- JHC FIXME remove exe-sources
        cleanJHCExtras lbi = do
            chattyTry "removing jhc-pkg.conf" $
                       removeFile (buildDir lbi </> "jhc-pkg.conf")
            removePreprocessedPackage pkg_descr currentDir ["ho"]
        removeFileOrDirectory :: FilePath -> IO ()
        removeFileOrDirectory fname = do
            isDir <- doesDirectoryExist fname
            isFile <- doesFileExist fname
            if isDir then removeDirectoryRecursive fname
              else if isFile then removeFile fname
              else return ()
        verbosity = fromFlag (cleanVerbose flags)

-- --------------------------------------------------------------------------
-- Default hooks

no_extra_flags :: [String] -> IO ()
no_extra_flags [] = return ()
no_extra_flags extra_flags =
 die $ concat
     $ intersperse "\n" ("Unrecognised flags:" : map (' ' :) extra_flags)

-- | Hooks that correspond to a plain instantiation of the 
-- \"simple\" build system
simpleUserHooks :: UserHooks
simpleUserHooks = 
    emptyUserHooks {
       confHook  = configure,
       buildHook = defaultBuildHook,
       makefileHook = defaultMakefileHook,
       copyHook  = \desc lbi _ f -> install desc lbi f, -- has correct 'copy' behavior with params
       instHook  = defaultInstallHook,
       sDistHook = \p l h f -> sdist p l f srcPref distPref (allSuffixHandlers h),
       pfeHook   = \p _ h f -> pfe   p (allSuffixHandlers h) f,
       cleanHook = \p l _ f -> clean p l f,
       hscolourHook = \p l h f -> hscolour p l (allSuffixHandlers h) f,
       haddockHook  = \p l h f -> haddock  p l (allSuffixHandlers h) f,
       regHook   = defaultRegHook,
       unregHook = \p l _ f -> unregister p l f
      }

-- | Basic autoconf 'UserHooks':
--
-- * on non-Windows systems, 'postConf' runs @.\/configure@, if present.
--
-- * the pre-hooks 'preBuild', 'preClean', 'preCopy', 'preInst',
--   'preReg' and 'preUnreg' read additional build information from
--   /package/@.buildinfo@, if present.
--
-- Thus @configure@ can use local system information to generate
-- /package/@.buildinfo@ and possibly other files.

-- FIXME: do something sensible for windows, or do nothing in postConf.

{-# DEPRECATED defaultUserHooks "Use simpleUserHooks or autoconfUserHooks" #-}
defaultUserHooks :: UserHooks
defaultUserHooks = autoconfUserHooks {
          confHook = \pkg flags -> do
	               let verbosity = fromFlag (configVerbose flags)
		       warn verbosity $
		         "defaultUserHooks in Setup script is deprecated."
	               confHook autoconfUserHooks pkg flags,
          postConf = oldCompatPostConf
    }
    -- This is the annoying old version that only runs configure if it exists.
    -- It's here for compatability with existing Setup.hs scripts. See:
    -- http://hackage.haskell.org/trac/hackage/ticket/165
    where oldCompatPostConf args flags _ _
              = do let verbosity = fromFlag (configVerbose flags)
                   no_extra_flags args
                   confExists <- doesFileExist "configure"
                   when confExists $
                       rawSystemPathExit verbosity "sh" $
                       "configure" : configureArgs flags

autoconfUserHooks :: UserHooks
autoconfUserHooks
    = simpleUserHooks
      {
       postConf  = defaultPostConf,
       preBuild  = readHook buildVerbose,
       preMakefile = readHook makefileVerbose,
       preClean  = readHook cleanVerbose,
       preCopy   = readHook copyVerbose,
       preInst   = readHook installVerbose,
       preHscolour = readHook hscolourVerbose,
       preHaddock  = readHook haddockVerbose,
       preReg    = readHook regVerbose,
       preUnreg  = readHook regVerbose
      }
    where defaultPostConf :: Args -> ConfigFlags -> PackageDescription -> LocalBuildInfo -> IO ()
          defaultPostConf args flags _ _
              = do let verbosity = fromFlag (configVerbose flags)
                   no_extra_flags args
                   confExists <- doesFileExist "configure"
                   if confExists
                     then rawSystemExit verbosity "sh" $
                            "configure" : configureArgs flags
                     else die "configure script not found."

          readHook :: (a -> Flag Verbosity) -> Args -> a -> IO HookedBuildInfo
          readHook get_verbosity a flags = do
              no_extra_flags a
              maybe_infoFile <- defaultHookedPackageDesc
              case maybe_infoFile of
                  Nothing       -> return emptyHookedBuildInfo
                  Just infoFile -> do
                      let verbosity = fromFlag (get_verbosity flags)
                      info verbosity $ "Reading parameters from " ++ infoFile
                      readHookedBuildInfo verbosity infoFile

defaultInstallHook :: PackageDescription -> LocalBuildInfo
                   -> UserHooks -> InstallFlags -> IO ()
defaultInstallHook pkg_descr localbuildinfo _ flags = do
  install pkg_descr localbuildinfo defaultCopyFlags {
    copyDest    = toFlag NoCopyDest,
    copyVerbose = installVerbose flags
  }
  when (hasLibs pkg_descr) $
      register pkg_descr localbuildinfo defaultRegisterFlags {
        regPackageDB = installPackageDB flags,
        regVerbose   = installVerbose flags
      }

defaultBuildHook :: PackageDescription -> LocalBuildInfo
	-> UserHooks -> BuildFlags -> IO ()
defaultBuildHook pkg_descr localbuildinfo hooks flags = do
  build pkg_descr localbuildinfo flags (allSuffixHandlers hooks)
  when (hasLibs pkg_descr) $
      writeInstalledConfig pkg_descr localbuildinfo False Nothing

defaultMakefileHook :: PackageDescription -> LocalBuildInfo
	-> UserHooks -> MakefileFlags -> IO ()
defaultMakefileHook pkg_descr localbuildinfo hooks flags = do
  makefile pkg_descr localbuildinfo flags (allSuffixHandlers hooks)
  when (hasLibs pkg_descr) $
      writeInstalledConfig pkg_descr localbuildinfo False Nothing

defaultRegHook :: PackageDescription -> LocalBuildInfo
	-> UserHooks -> RegisterFlags -> IO ()
defaultRegHook pkg_descr localbuildinfo _ flags =
    if hasLibs pkg_descr
    then register pkg_descr localbuildinfo flags
    else setupMessage verbosity
           "Package contains no library to register:" pkg_descr
  where verbosity = fromFlag (regVerbose flags)

-- ------------------------------------------------------------
-- * Testing
-- ------------------------------------------------------------
#ifdef DEBUG
simpleHunitTests :: [Test]
simpleHunitTests = []
#endif
