{-# LANGUAGE BangPatterns #-}

module Main where

import Codec.Archive.Tar as Tar
import Control.Exception (Exception, throwIO)
import Control.Monad.IO.Class
import Control.Monad.State.Lazy (state)
import Data.Map.Lazy as Map
import Data.Traversable
import System.Exit (ExitCode(ExitSuccess))
import System.FilePath
import System.IO
import System.Process (readCreateProcessWithExitCode, shell)
import Z3.Monad as Z3

import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Encoding.Error as T
import qualified Data.Text.Lazy as Tl
import qualified Data.Text.Lazy.Encoding as Tl

import Distribution.Compat.ReadP (readP_to_S)
import Distribution.Compiler
import Distribution.Package
import Distribution.PackageDescription
import Distribution.PackageDescription.Parse
import Distribution.PackageDescription.PrettyPrint (showGenericPackageDescription)
import Distribution.Text as Dt
import Distribution.Version

import Development.Hake.Solver

import qualified Data.ByteString.Lazy as Bl

packageTarball :: IO String
packageTarball = do
  let cmd = shell "grep remote-repo-cache ~/.cabal/config | awk '{print $2}'"
  (ExitSuccess, dirs, _) <- readCreateProcessWithExitCode cmd ""
  case lines dirs of
    [dir] -> return $ combine dir "hackage.haskell.org/00-index.tar"
    _ -> fail "uhm"

foldEntriesM :: (Exception e, MonadIO m) => (a -> Entry -> m a) -> a -> Entries e -> m a
foldEntriesM f = step where
  step !s (Next e es) = f s e >>= flip step es
  step s Tar.Done = return s
  step _ (Fail e) = liftIO $ throwIO e

takeEntries :: Int -> Entries e -> Entries e
takeEntries 0 _ = Tar.Done
takeEntries i (Next e es) = Next e (takeEntries (i-1) es)
takeEntries _ x = x

loadPackageDescriptions
  :: Map PackageIdentifier GenericPackageDescription
  -> Entry
  -> IO (Map PackageIdentifier GenericPackageDescription)
loadPackageDescriptions !agg e
  | ".cabal" <- takeExtension (entryPath e)
  , NormalFile lbs _fs <- entryContent e
  , ParseOk _ gpd <- parsePackageDescription (Tl.unpack (Tl.decodeUtf8With T.ignore lbs)) = do
      putChar '.'
      hFlush stdout
      return $ Map.insert (packageId gpd) gpd agg

  | otherwise = do
      putChar 'x'
      hFlush stdout
      return agg

loadGlobalDatabase :: HakeSolverT Z3 ()
loadGlobalDatabase = do
  entries <- liftIO $ Tar.read <$> (Bl.readFile =<< packageTarball)
  let entries' = takeEntries 1000 entries
  gpdMap <- liftIO $ foldEntriesM loadPackageDescriptions Map.empty entries'
  let gpdHakeMap = splitPackageIdentifiers gpdMap
  state (\ x -> ((), x{hakeSolverGenDesc = gpdHakeMap}))

query :: Z3 (Result, Maybe String)
query = do
  x <- mkFreshBoolVar "x"
  assert x
  (res, mmodel) <- getModel
  case mmodel of
    Just model -> do
      str <- modelToString model
      return (res, Just str)
    Nothing -> return (res, Nothing)

defaultSolverState :: HakeSolverState
defaultSolverState =
  HakeSolverState
    { hakeSolverGenDesc = Map.empty
    , hakeSolverVars = Map.empty
    , hakeSolverPkgs = Map.empty
    }

main :: IO ()
main = do
  env <- Z3.newEnv (Just QF_BV) stdOpts
  st <- execHakeSolverT defaultSolverState env loadGlobalDatabase

  let prog = do
        x <- getDependency $ Dependency (PackageName "Coroutine") anyVersion
        assert x
        (res, mmodel) <- getModel
        case mmodel of
          Just model -> do
            str <- modelToString model
            return (res, Just str)
          Nothing -> return (res, Nothing)

  (x, st') <- runLocalHakeSolverT st env prog

  print x
