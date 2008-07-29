-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.PackageDescription.Parse
-- Copyright   :  Isaac Jones 2003-2005
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- This defined parsers and partial pretty printers for the @.cabal@ format.
-- Some of the complexity in this module is due to the fact that we have to be
-- backwards compatible with old @.cabal@ files, so there's code to translate
-- into the newer structure.

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

module Distribution.PackageDescription.Parse (
        -- * Package descriptions
        readPackageDescription,
        writePackageDescription,
        parsePackageDescription,
        showPackageDescription,

        -- ** Parsing
        ParseResult(..),
        FieldDescr(..),
        LineNo,

        -- ** Supplementary build information
        readHookedBuildInfo,
        parseHookedBuildInfo,
        writeHookedBuildInfo,
        showHookedBuildInfo,
  ) where

import Data.Char  (isSpace)
import Data.Maybe (listToMaybe)
import Data.List  (nub, unfoldr, partition, (\\))
import Control.Monad (liftM, foldM, when, unless)
import System.Directory (doesFileExist)

import Distribution.Text
         ( Text(disp, parse), display, simpleParse )
import Text.PrettyPrint.HughesPJ
import Distribution.Compat.ReadP hiding (get)

import Distribution.ParseUtils
import Distribution.PackageDescription
import Distribution.Package
         ( PackageName(..), PackageIdentifier(..), Dependency(..)
         , packageName, packageVersion )
import Distribution.Version
        ( VersionRange(AnyVersion), isAnyVersion, withinRange )
import Distribution.Verbosity (Verbosity)
import Distribution.Compiler  (CompilerFlavor(..))
import Distribution.PackageDescription.Configuration (parseCondition, freeVars)
import Distribution.Simple.Utils
         ( die, dieWithLocation, warn, intercalate, lowercase, cabalVersion
         , withFileContents, withUTF8FileContents
         , writeFileAtomic, writeUTF8File )


-- -----------------------------------------------------------------------------
-- The PackageDescription type

pkgDescrFieldDescrs :: [FieldDescr PackageDescription]
pkgDescrFieldDescrs =
    [ simpleField "name"
           disp                   parse
           packageName            (\name pkg -> pkg{package=(package pkg){pkgName=name}})
 , simpleField "version"
           disp                   parse
           packageVersion         (\ver pkg -> pkg{package=(package pkg){pkgVersion=ver}})
 , simpleField "cabal-version"
           disp                   parse
           descCabalVersion       (\v pkg -> pkg{descCabalVersion=v})
 , simpleField "build-type"
           (maybe empty disp)     (fmap Just parse)
           buildType              (\t pkg -> pkg{buildType=t})
 , simpleField "license"
           disp                   parseLicenseQ
           license                (\l pkg -> pkg{license=l})
 , simpleField "license-file"
           showFilePath           parseFilePathQ
           licenseFile            (\l pkg -> pkg{licenseFile=l})
 , simpleField "copyright"
           showFreeText           (munch (const True))
           copyright              (\val pkg -> pkg{copyright=val})
 , simpleField "maintainer"
           showFreeText           (munch (const True))
           maintainer             (\val pkg -> pkg{maintainer=val})
 , commaListField  "build-depends"
           disp                   parse
           buildDepends           (\xs    pkg -> pkg{buildDepends=xs})
 , simpleField "stability"
           showFreeText           (munch (const True))
           stability              (\val pkg -> pkg{stability=val})
 , simpleField "homepage"
           showFreeText           (munch (const True))
           homepage               (\val pkg -> pkg{homepage=val})
 , simpleField "package-url"
           showFreeText           (munch (const True))
           pkgUrl                 (\val pkg -> pkg{pkgUrl=val})
 , simpleField "synopsis"
           showFreeText           (munch (const True))
           synopsis               (\val pkg -> pkg{synopsis=val})
 , simpleField "description"
           showFreeText           (munch (const True))
           description            (\val pkg -> pkg{description=val})
 , simpleField "category"
           showFreeText           (munch (const True))
           category               (\val pkg -> pkg{category=val})
 , simpleField "author"
           showFreeText           (munch (const True))
           author                 (\val pkg -> pkg{author=val})
 , listField "tested-with"
           showTestedWith         parseTestedWithQ
           testedWith             (\val pkg -> pkg{testedWith=val})
 , listField "data-files"
           showFilePath           parseFilePathQ
           dataFiles              (\val pkg -> pkg{dataFiles=val})
 , simpleField "data-dir"
           showFilePath           parseFilePathQ
           dataDir                (\val pkg -> pkg{dataDir=val})
 , listField "extra-source-files"
           showFilePath    parseFilePathQ
           extraSrcFiles          (\val pkg -> pkg{extraSrcFiles=val})
 , listField "extra-tmp-files"
           showFilePath       parseFilePathQ
           extraTmpFiles          (\val pkg -> pkg{extraTmpFiles=val})
 ]

-- | Store any fields beginning with "x-" in the customFields field of
--   a PackageDescription.  All other fields will generate a warning.
storeXFieldsPD :: UnrecFieldParser PackageDescription
storeXFieldsPD (f@('x':'-':_),val) pkg = Just pkg{ customFieldsPD = (f,val):(customFieldsPD pkg) }
storeXFieldsPD _ _ = Nothing

-- ---------------------------------------------------------------------------
-- The Library type

libFieldDescrs :: [FieldDescr Library]
libFieldDescrs = map biToLib binfoFieldDescrs
  ++ [
      listField "exposed-modules" disp parseModuleNameQ
         exposedModules (\mods lib -> lib{exposedModules=mods})
     ]
  where biToLib = liftField libBuildInfo (\bi lib -> lib{libBuildInfo=bi})

storeXFieldsLib :: UnrecFieldParser Library
storeXFieldsLib (f@('x':'-':_), val) l@(Library { libBuildInfo = bi }) =
    Just $ l {libBuildInfo = bi{ customFieldsBI = (f,val):(customFieldsBI bi) }}
storeXFieldsLib _ _ = Nothing

-- ---------------------------------------------------------------------------
-- The Executable type


executableFieldDescrs :: [FieldDescr Executable]
executableFieldDescrs =
  [ -- note ordering: configuration must come first, for
    -- showPackageDescription.
    simpleField "executable"
                           showToken          parseTokenQ
                           exeName            (\xs    exe -> exe{exeName=xs})
  , simpleField "main-is"
                           showFilePath       parseFilePathQ
                           modulePath         (\xs    exe -> exe{modulePath=xs})
  ]
  ++ map biToExe binfoFieldDescrs
  where biToExe = liftField buildInfo (\bi exe -> exe{buildInfo=bi})

storeXFieldsExe :: UnrecFieldParser Executable
storeXFieldsExe (f@('x':'-':_), val) e@(Executable { buildInfo = bi }) =
    Just $ e {buildInfo = bi{ customFieldsBI = (f,val):(customFieldsBI bi)}}
storeXFieldsExe _ _ = Nothing

-- ---------------------------------------------------------------------------
-- The BuildInfo type


binfoFieldDescrs :: [FieldDescr BuildInfo]
binfoFieldDescrs =
 [ boolField "buildable"
           buildable          (\val binfo -> binfo{buildable=val})
 , commaListField  "build-tools"
           disp               parseBuildTool
           buildTools         (\xs  binfo -> binfo{buildTools=xs})
 , spaceListField "cpp-options"
           showToken          parseTokenQ
           cppOptions          (\val binfo -> binfo{cppOptions=val})
 , spaceListField "cc-options"
           showToken          parseTokenQ
           ccOptions          (\val binfo -> binfo{ccOptions=val})
 , spaceListField "ld-options"
           showToken          parseTokenQ
           ldOptions          (\val binfo -> binfo{ldOptions=val})
 , commaListField  "pkgconfig-depends"
           disp               parsePkgconfigDependency
           pkgconfigDepends   (\xs  binfo -> binfo{pkgconfigDepends=xs})
 , listField "frameworks"
           showToken          parseTokenQ
           frameworks         (\val binfo -> binfo{frameworks=val})
 , listField   "c-sources"
           showFilePath       parseFilePathQ
           cSources           (\paths binfo -> binfo{cSources=paths})
 , listField   "extensions"
           disp               parseExtensionQ
           extensions         (\exts  binfo -> binfo{extensions=exts})
 , listField   "extra-libraries"
           showToken          parseTokenQ
           extraLibs          (\xs    binfo -> binfo{extraLibs=xs})
 , listField   "extra-lib-dirs"
           showFilePath       parseFilePathQ
           extraLibDirs       (\xs    binfo -> binfo{extraLibDirs=xs})
 , listField   "includes"
           showFilePath       parseFilePathQ
           includes           (\paths binfo -> binfo{includes=paths})
 , listField   "install-includes"
           showFilePath       parseFilePathQ
           installIncludes    (\paths binfo -> binfo{installIncludes=paths})
 , listField   "include-dirs"
           showFilePath       parseFilePathQ
           includeDirs        (\paths binfo -> binfo{includeDirs=paths})
 , listField   "hs-source-dirs"
           showFilePath       parseFilePathQ
           hsSourceDirs       (\paths binfo -> binfo{hsSourceDirs=paths})
 , listField   "other-modules"
           disp               parseModuleNameQ
           otherModules       (\val binfo -> binfo{otherModules=val})
 , listField   "ghc-prof-options"
           text               parseTokenQ
           ghcProfOptions        (\val binfo -> binfo{ghcProfOptions=val})
 , listField   "ghc-shared-options"
           text               parseTokenQ
           ghcProfOptions        (\val binfo -> binfo{ghcSharedOptions=val})
 , optsField   "ghc-options"  GHC
           options            (\path  binfo -> binfo{options=path})
 , optsField   "hugs-options" Hugs
           options            (\path  binfo -> binfo{options=path})
 , optsField   "nhc98-options"  NHC
           options            (\path  binfo -> binfo{options=path})
 , optsField   "jhc-options"  JHC
           options            (\path  binfo -> binfo{options=path})
 ]

storeXFieldsBI :: UnrecFieldParser BuildInfo
storeXFieldsBI (f@('x':'-':_),val) bi = Just bi{ customFieldsBI = (f,val):(customFieldsBI bi) }
storeXFieldsBI _ _ = Nothing

------------------------------------------------------------------------------

flagFieldDescrs :: [FieldDescr Flag]
flagFieldDescrs =
    [ simpleField "description"
        showFreeText     (munch (const True))
        flagDescription  (\val fl -> fl{ flagDescription = val })
    , boolField "default"
        flagDefault      (\val fl -> fl{ flagDefault = val })
    ]

-- ---------------------------------------------------------------
-- Parsing

-- | Given a parser and a filename, return the parse of the file,
-- after checking if the file exists.
readAndParseFile :: (FilePath -> (String -> IO a) -> IO a)
                 -> (String -> ParseResult a)
                 -> Verbosity
                 -> FilePath -> IO a
readAndParseFile withFileContents' parser verbosity fpath = do
  exists <- doesFileExist fpath
  when (not exists) (die $ "Error Parsing: file \"" ++ fpath ++ "\" doesn't exist. Cannot continue.")
  withFileContents' fpath $ \str -> case parser str of
    ParseFailed e -> do
        let (line, message) = locatedErrorMsg e
        dieWithLocation fpath line message
    ParseOk warnings x -> do
        mapM_ (warn verbosity . showPWarning fpath) $ reverse warnings
        return x

readHookedBuildInfo :: Verbosity -> FilePath -> IO HookedBuildInfo
readHookedBuildInfo =
    readAndParseFile withFileContents parseHookedBuildInfo

-- |Parse the given package file.
readPackageDescription :: Verbosity -> FilePath -> IO GenericPackageDescription
readPackageDescription =
    readAndParseFile withUTF8FileContents parsePackageDescription

stanzas :: [Field] -> [[Field]]
stanzas [] = []
stanzas (f:fields) = (f:this) : stanzas rest
  where
    (this, rest) = break isStanzaHeader fields

isStanzaHeader :: Field -> Bool
isStanzaHeader (F _ f _) = f == "executable"
isStanzaHeader _ = False

------------------------------------------------------------------------------


mapSimpleFields :: (Field -> ParseResult Field) -> [Field]
                -> ParseResult [Field]
mapSimpleFields f fs = mapM walk fs
  where
    walk fld@(F _ _ _) = f fld
    walk (IfBlock l c fs1 fs2) = do
      fs1' <- mapM walk fs1
      fs2' <- mapM walk fs2
      return (IfBlock l c fs1' fs2')
    walk (Section ln n l fs1) = do
      fs1' <-  mapM walk fs1
      return (Section ln n l fs1')

-- prop_isMapM fs = mapSimpleFields return fs == return fs


-- names of fields that represents dependencies, thus consrca
constraintFieldNames :: [String]
constraintFieldNames = ["build-depends"]

-- Possible refactoring would be to have modifiers be explicit about what
-- they add and define an accessor that specifies what the dependencies
-- are.  This way we would completely reuse the parsing knowledge from the
-- field descriptor.
parseConstraint :: Field -> ParseResult [Dependency]
parseConstraint (F l n v)
    | n == "build-depends" = runP l n (parseCommaList parse) v
parseConstraint f = bug $ "Constraint was expected (got: " ++ show f ++ ")"

{-
headerFieldNames :: [String]
headerFieldNames = filter (\n -> not (n `elem` constraintFieldNames))
                 . map fieldName $ pkgDescrFieldDescrs
-}

libFieldNames :: [String]
libFieldNames = map fieldName libFieldDescrs
                ++ buildInfoNames ++ constraintFieldNames

-- exeFieldNames :: [String]
-- exeFieldNames = map fieldName executableFieldDescrs
--                 ++ buildInfoNames

buildInfoNames :: [String]
buildInfoNames = map fieldName binfoFieldDescrs
                ++ map fst deprecatedFieldsBuildInfo

-- A minimal implementation of the StateT monad transformer to avoid depending
-- on the 'mtl' package.
newtype StT s m a = StT { runStT :: s -> m (a,s) }

instance Monad m => Monad (StT s m) where
    return a = StT (\s -> return (a,s))
    StT f >>= g = StT $ \s -> do
                        (a,s') <- f s
                        runStT (g a) s'

get :: Monad m => StT s m s
get = StT $ \s -> return (s, s)

modify :: Monad m => (s -> s) -> StT s m ()
modify f = StT $ \s -> return ((),f s)

lift :: Monad m => m a -> StT s m a
lift m = StT $ \s -> m >>= \a -> return (a,s)

evalStT :: Monad m => StT s m a -> s -> m a
evalStT st s = runStT st s >>= return . fst

-- Our monad for parsing a list/tree of fields.
--
-- The state represents the remaining fields to be processed.
type PM a = StT [Field] ParseResult a



-- return look-ahead field or nothing if we're at the end of the file
peekField :: PM (Maybe Field)
peekField = get >>= return . listToMaybe

-- Unconditionally discard the first field in our state.  Will error when it
-- reaches end of file.  (Yes, that's evil.)
skipField :: PM ()
skipField = modify tail

-- | Parses the given file into a 'GenericPackageDescription'.
--
-- In Cabal 1.2 the syntax for package descriptions was changed to a format
-- with sections and possibly indented property descriptions.
parsePackageDescription :: String -> ParseResult GenericPackageDescription
parsePackageDescription file = do
    let tabs = findIndentTabs file

    fields0 <- readFields file `catchParseError` \err ->
                 case err of
                   -- In case of a TabsError report them all at once.
                   TabsError tabLineNo -> reportTabsError
                   -- but only report the ones including and following
                   -- the one that caused the actual error
                                            [ t | t@(lineNo',_) <- tabs
                                                , lineNo' >= tabLineNo ]
                   _ -> parseFail err

    let cabalVersionNeeded =
          head $ [ versionRange
                 | Just versionRange <- [ simpleParse v
                                        | F _ "cabal-version" v <- fields0 ] ]
              ++ [AnyVersion]
    handleFutureVersionParseFailure cabalVersionNeeded $ do

      let sf = sectionizeFields fields0
      fields <- mapSimpleFields deprecField sf

      flip evalStT fields $ do
        hfs <- getHeader []
        pkg <- lift $ parseFields pkgDescrFieldDescrs storeXFieldsPD emptyPackageDescription hfs
        (flags, mlib, exes) <- getBody
        warnIfRest
        when (not (oldSyntax fields0)) $
          maybeWarnCabalVersion pkg
        checkForUndefinedFlags flags mlib exes
        return (GenericPackageDescription pkg flags mlib exes)

  where
    oldSyntax flds = all isSimpleField flds
    reportTabsError tabs =
        syntaxError (fst (head tabs)) $
          "Do not use tabs for indentation (use spaces instead)\n"
          ++ "  Tabs were used at (line,column): " ++ show tabs
    maybeWarnCabalVersion pkg =
        when (packageName pkg /= PackageName "Cabal" -- supress warning for Cabal
           && isAnyVersion (descCabalVersion pkg)) $
          lift $ warning $
            "A package using section syntax should require\n"
            ++ "\"Cabal-Version: >= 1.2\" or equivalent."

    handleFutureVersionParseFailure cabalVersionNeeded parseBody =
      (unless versionOk (warning message) >> parseBody)
        `catchParseError` \parseError -> case parseError of
        TabsError _   -> parseFail parseError
        _ | versionOk -> parseFail parseError
          | otherwise -> fail message
      where versionOk = cabalVersion `withinRange` cabalVersionNeeded
            message   = "This package requires Cabal version: "
                     ++ display cabalVersionNeeded

    -- "Sectionize" an old-style Cabal file.  A sectionized file has:
    --
    --  * all global fields at the beginning, followed by
    --  * all flag declarations, followed by
    --  * an optional library section, and
    --  * an arbitrary number of executable sections.
    --
    -- The current implementatition just gathers all library-specific fields
    -- in a library section and wraps all executable stanzas in an executable
    -- section.
    sectionizeFields :: [Field] -> [Field]
    sectionizeFields fs
      | oldSyntax fs =
          let
            -- "build-depends" is a local field now.  To be backwards
            -- compatible, we still allow it as a global field in old-style
            -- package description files and translate it to a local field by
            -- adding it to every non-empty section
            (hdr0, exes0) = break ((=="executable") . fName) fs
            (hdr, libfs0) = partition (not . (`elem` libFieldNames) . fName) hdr0

            (deps, libfs) = partition ((== "build-depends") . fName)
                                       libfs0

            exes = unfoldr toExe exes0
            toExe [] = Nothing
            toExe (F l e n : r)
              | e == "executable" =
                  let (efs, r') = break ((=="executable") . fName) r
                  in Just (Section l "executable" n (deps ++ efs), r')
            toExe _ = bug "unexpeced input to 'toExe'"
          in
            hdr ++
           (if null libfs then []
            else [Section (lineNo (head libfs)) "library" "" (deps ++ libfs)])
            ++ exes
      | otherwise = fs

    isSimpleField (F _ _ _) = True
    isSimpleField _ = False

    -- warn if there's something at the end of the file
    warnIfRest :: PM ()
    warnIfRest = do
      s <- get
      case s of
        [] -> return ()
        _ -> lift $ warning "Ignoring trailing declarations."  -- add line no.

    -- all simple fields at the beginning of the file are (considered) header
    -- fields
    getHeader :: [Field] -> PM [Field]
    getHeader acc = peekField >>= \mf -> case mf of
        Just f@(F _ _ _) -> skipField >> getHeader (f:acc)
        _ -> return (reverse acc)

    --
    -- body ::= flag* { library | executable }+   -- at most one lib
    --
    -- The body consists of an optional sequence of flag declarations and after
    -- that an arbitrary number of executables and an optional library.  The
    -- order of the latter doesn't play a role.
    getBody :: PM ([Flag]
                  ,Maybe (CondTree ConfVar [Dependency] Library)
                  ,[(String, CondTree ConfVar [Dependency] Executable)])
    getBody = do
      mf <- peekField
      case mf of
        Just (Section _ sn _label _fields)
          | sn == "flag"    -> do
              -- don't skipField here.  it's simpler to let getFlags do it
              -- itself
              flags <- getFlags []
              (lib, exes) <- getLibOrExe
              return (flags, lib, exes)
          | otherwise -> do
              (lib,exes) <- getLibOrExe
              return ([], lib, exes)
        Nothing -> do lift $ warning "No library or executable specified"
                      return ([], Nothing, [])
        Just f -> lift $ syntaxError (lineNo f) $
               "Construct not supported at this position: " ++ show f

    --
    -- flags ::= "flag:" name { flag_prop }
    --
    getFlags :: [Flag] -> StT [Field] ParseResult [Flag]
    getFlags acc = peekField >>= \mf -> case mf of
        Just (Section _ sn sl fs)
          | sn == "flag" -> do
              fl <- lift $ parseFields
                      flagFieldDescrs
                      warnUnrec
                      (MkFlag (FlagName (lowercase sl)) "" True)
                      fs
              skipField >> getFlags (fl : acc)
        _ -> return (reverse acc)

    getLibOrExe :: PM (Maybe (CondTree ConfVar [Dependency] Library)
                      ,[(String, CondTree ConfVar [Dependency] Executable)])
    getLibOrExe = peekField >>= \mf -> case mf of
        Just (Section n sn sl fs)
          | sn == "executable" -> do
              when (null sl) $ lift $
                syntaxError n "'executable' needs one argument (the executable's name)"
              exename <- lift $ runP n "executable" parseTokenQ sl
              flds <- collectFields parseExeFields fs
              skipField
              (lib, exes) <- getLibOrExe
              return (lib, exes ++ [(exename, flds)])
          | sn == "library" -> do
              when (not (null sl)) $ lift $
                syntaxError n "'library' expects no argument"
              flds <- collectFields parseLibFields fs
              skipField
              (lib, exes) <- getLibOrExe
              return (maybe (Just flds)
                            (const (error "Multiple libraries specified"))
                            lib
                     , exes)
          | otherwise -> do
              lift $ warning $ "Unknown section type: " ++ sn ++ " ignoring..."
              return (Nothing, []) -- yep
        Just x -> lift $ syntaxError (lineNo x) $ "Section expected."
        Nothing -> return (Nothing, [])

    -- extracts all fields in a block, possibly add dependencies to the
    -- guard condition
    collectFields :: ([Field] -> PM a) -> [Field]
                  -> PM (CondTree ConfVar [Dependency] a)
    collectFields parser allflds = do
        a <- parser dataFlds
        deps <- liftM concat . mapM (lift . parseConstraint) $ depFlds
        ifs <- mapM processIfs condFlds
        return (CondNode a deps ifs)
      where
        (depFlds, dataFlds) = partition isConstraint simplFlds
        simplFlds = [ F l n v | F l n v <- allflds ]
        condFlds = [ f | f@(IfBlock _ _ _ _) <- allflds ]
        isConstraint (F _ n _) = n `elem` constraintFieldNames
        isConstraint _ = False
        processIfs (IfBlock l c t e) = do
            cnd <- lift $ runP l "if" parseCondition c
            t' <- collectFields parser t
            e' <- case e of
                   [] -> return Nothing
                   es -> do fs <- collectFields parser es
                            return (Just fs)
            return (cnd, t', e')
        processIfs _ = bug "processIfs called with wrong field type"

    parseLibFields :: [Field] -> StT s ParseResult Library
    parseLibFields = lift . parseFields libFieldDescrs storeXFieldsLib emptyLibrary

    parseExeFields :: [Field] -> StT s ParseResult Executable
    parseExeFields = lift . parseFields executableFieldDescrs storeXFieldsExe emptyExecutable

    checkForUndefinedFlags ::
        [Flag] ->
        Maybe (CondTree ConfVar [Dependency] Library) ->
        [(String, CondTree ConfVar [Dependency] Executable)] ->
        PM ()
    checkForUndefinedFlags flags mlib exes = do
        let definedFlags = map flagName flags
        maybe (return ()) (checkCondTreeFlags definedFlags) mlib
        mapM_ (checkCondTreeFlags definedFlags . snd) exes

    checkCondTreeFlags :: [FlagName] -> CondTree ConfVar c a -> PM ()
    checkCondTreeFlags definedFlags ct = do
        let fv = nub $ freeVars ct
        when (not . all (`elem` definedFlags) $ fv) $
            fail $ "These flags are used without having been defined: "
                ++ intercalate ", " [ n | FlagName n <- fv \\ definedFlags ]


-- | Parse a list of fields, given a list of field descriptions,
--   a structure to accumulate the parsed fields, and a function
--   that can decide what to do with fields which don't match any
--   of the field descriptions.
parseFields :: [FieldDescr a]      -- ^ list of parseable fields
            -> UnrecFieldParser a  -- ^ possibly do something with
                                   --   unrecognized fields
            -> a                   -- ^ accumulator
            -> [Field]             -- ^ fields to be parsed
            -> ParseResult a
parseFields descrs unrec ini fields =
    do (a, unknowns) <- foldM (parseField descrs unrec) (ini, []) fields
       when (not (null unknowns)) $ do
         warning $ render $
           text "Unknown fields:" <+>
                commaSep (map (\(l,u) -> u ++ " (line " ++ show l ++ ")")
                              (reverse unknowns))
           $+$
           text "Fields allowed in this section:" $$
             nest 4 (commaSep $ map fieldName descrs)
       return a
  where
    commaSep = fsep . punctuate comma . map text

parseField :: [FieldDescr a]     -- ^ list of parseable fields
           -> UnrecFieldParser a -- ^ possibly do something with
                                 --   unrecognized fields
           -> (a,[(Int,String)]) -- ^ accumulated result and warnings
           -> Field              -- ^ the field to be parsed
           -> ParseResult (a, [(Int,String)])
parseField ((FieldDescr name _ parser):fields) unrec (a, us) (F line f val)
  | name == f = parser line val a >>= \a' -> return (a',us)
  | otherwise = parseField fields unrec (a,us) (F line f val)
parseField [] unrec (a,us) (F l f val) = return $
  case unrec (f,val) a of        -- no fields matched, see if the 'unrec'
    Just a' -> (a',us)           -- function wants to do anything with it
    Nothing -> (a, ((l,f):us))
parseField _ _ _ _ = bug "'parseField' called on a non-field"

deprecatedFields :: [(String,String)]
deprecatedFields =
    deprecatedFieldsPkgDescr ++ deprecatedFieldsBuildInfo

deprecatedFieldsPkgDescr :: [(String,String)]
deprecatedFieldsPkgDescr = [ ("other-files", "extra-source-files") ]

deprecatedFieldsBuildInfo :: [(String,String)]
deprecatedFieldsBuildInfo = [ ("hs-source-dir","hs-source-dirs") ]

-- Handle deprecated fields
deprecField :: Field -> ParseResult Field
deprecField (F line fld val) = do
  fld' <- case lookup fld deprecatedFields of
            Nothing -> return fld
            Just newName -> do
              warning $ "The field \"" ++ fld
                      ++ "\" is deprecated, please use \"" ++ newName ++ "\""
              return newName
  return (F line fld' val)
deprecField _ = bug "'deprecField' called on a non-field"


parseHookedBuildInfo :: String -> ParseResult HookedBuildInfo
parseHookedBuildInfo inp = do
  fields <- readFields inp
  let ss@(mLibFields:exes) = stanzas fields
  mLib <- parseLib mLibFields
  biExes <- mapM parseExe (maybe ss (const exes) mLib)
  return (mLib, biExes)
  where
    parseLib :: [Field] -> ParseResult (Maybe BuildInfo)
    parseLib (bi@((F _ inFieldName _):_))
        | lowercase inFieldName /= "executable" = liftM Just (parseBI bi)
    parseLib _ = return Nothing

    parseExe :: [Field] -> ParseResult (String, BuildInfo)
    parseExe ((F line inFieldName mName):bi)
        | lowercase inFieldName == "executable"
            = do bis <- parseBI bi
                 return (mName, bis)
        | otherwise = syntaxError line "expecting 'executable' at top of stanza"
    parseExe (_:_) = bug "`parseExe' called on a non-field"
    parseExe [] = syntaxError 0 "error in parsing buildinfo file. Expected executable stanza"

    parseBI st = parseFields binfoFieldDescrs storeXFieldsBI emptyBuildInfo st

-- ---------------------------------------------------------------------------
-- Pretty printing

writePackageDescription :: FilePath -> PackageDescription -> IO ()
writePackageDescription fpath pkg = writeUTF8File fpath (showPackageDescription pkg)

showPackageDescription :: PackageDescription -> String
showPackageDescription pkg = render $
  ppFields pkg pkgDescrFieldDescrs $$
  ppCustomFields (customFieldsPD pkg) $$
  (case library pkg of
     Nothing  -> empty
     Just lib -> ppFields lib libFieldDescrs) $$
  vcat (map ppExecutable (executables pkg))
  where
    ppExecutable exe = space $$ ppFields exe executableFieldDescrs

ppCustomFields :: [(String,String)] -> Doc
ppCustomFields flds = vcat (map ppCustomField flds)

ppCustomField :: (String,String) -> Doc
ppCustomField (name,val) = text name <> colon <+> showFreeText val

writeHookedBuildInfo :: FilePath -> HookedBuildInfo -> IO ()
writeHookedBuildInfo fpath = writeFileAtomic fpath . showHookedBuildInfo

showHookedBuildInfo :: HookedBuildInfo -> String
showHookedBuildInfo (mb_lib_bi, ex_bi) = render $
  (case mb_lib_bi of
     Nothing -> empty
     Just bi -> ppFields bi binfoFieldDescrs) $$
  vcat (map ppExeBuildInfo ex_bi)
  where
    ppExeBuildInfo (name, bi) =
      space $$
      text "executable:" <+> text name $$
      ppFields bi binfoFieldDescrs $$
      ppCustomFields (customFieldsBI bi)

-- replace all tabs used as indentation with whitespace, also return where
-- tabs were found
findIndentTabs :: String -> [(Int,Int)]
findIndentTabs = concatMap checkLine
               . zip [1..]
               . lines
    where
      checkLine (lineno, l) =
          let (indent, _content) = span isSpace l
              tabCols = map fst . filter ((== '\t') . snd) . zip [0..]
              addLineNo = map (\col -> (lineno,col))
          in addLineNo (tabCols indent)

--test_findIndentTabs = findIndentTabs $ unlines $
--    [ "foo", "  bar", " \t baz", "\t  biz\t", "\t\t \t mib" ]

bug :: String -> a
bug msg = error $ msg ++ ". Consider this a bug."
