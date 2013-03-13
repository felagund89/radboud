module Main where

import Text.ParserCombinators.UU.Utils (runParser)
import System.Environment (getArgs)
import System.IO
import System.Console.GetOpt
import Text.Printf (printf)
import Control.Monad
import System.Exit

import Parser
import Prettyprint

main :: IO ()
main = do
  opts <- getArgs >>= get
  run opts

run :: Options -> IO ()
run opts = do
  case mode opts of
    ModePrettyprint -> do
      input <- hGetContents (inFile opts)
      let output = prettyprint $ runParser (inputFilename opts) pProgram input
      hPutStrLn (outFile opts) output

    ModeShow -> do
      input <- hGetContents (inFile opts)
      let output = show $ runParser (inputFilename opts) pProgram input
      hPutStrLn (outFile opts) output

    ModeHelp -> printHelp

    ModeCheckParser -> do
      input <- hGetContents (inFile opts)
      let ast1 = runParser (inputFilename opts) pProgram input
      let ast2 = runParser (inputFilename opts) pProgram $ prettyprint ast1
      print (ast1 == ast2)

  cleanUp opts

cleanUp :: Options -> IO ()
cleanUp opts = do
  hClose (inFile opts)
  hClose (outFile opts)

programName :: String
programName = "spl"

data Mode = ModeHelp | ModePrettyprint | ModeCheckParser | ModeShow
  deriving (Show)

data Options = Options
  { inFile :: Handle
  , inputFilename :: String
  , outFile :: Handle
  , outputFilename :: String
  , mode :: Mode
  }
  deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { inFile = stdin
  , inputFilename = "--"
  , outFile = stdout
  , outputFilename = "--"
  , mode = ModePrettyprint
  }

options :: [OptDescr (Options -> Options)]
options =
  [ Option []     ["help"]    (NoArg  (\  opts -> opts { mode = ModeHelp }))               "display this help and exit"
  , Option ['i']  ["input"]   (ReqArg (\s opts -> opts { inputFilename = s }) "FILE")  "file to read input from;\nuse \"--\" to read from stdin;\nwhen unspecified, defaults to stdin"
  , Option ['o']  ["output"]  (ReqArg (\s opts -> opts { outputFilename = s }) "FILE") "file to write output to;\nuse \"--\" to write to stdout;\nwhen unspecified, defaults to stdout"
  , Option []  ["check"]      (NoArg  (\  opts -> opts { mode = ModeCheckParser }))        "parse, prettyprint, parse and compare ASTs"
  , Option []  ["show"]       (NoArg  (\  opts -> opts { mode = ModeShow }))               "parse, then show"
  ]

get :: [String] -> IO Options
get args = do
  let (opts_, files, errors) = getOpt Permute options args
  let opts__ = foldl (flip id) defaultOptions opts_
  opts <- optOpenOutputFile opts__ >>= optOpenInputFile

  when ((not . null) errors)
    (tryHelp $ head errors)

  when ((not . null) files)
    (tryHelp $ printf "unrecognized option `%s'\n" $ head files)

  return opts

  where
    printAndExit :: String -> IO a
    printAndExit s = putStr s >> exitFailure

    tryHelp message = printAndExit $ programName ++ ": " ++ message
      ++ "Try `" ++ programName ++ " --help' for more information.\n"

optOpenInputFile :: Options -> IO Options
optOpenInputFile opts = do
  case (inputFilename opts) of
    "--" -> return opts { inFile = stdin }
    _    -> do
      handle <- openFile (inputFilename opts) ReadMode
      return opts { inFile = handle }

optOpenOutputFile :: Options -> IO Options
optOpenOutputFile opts = do
  case (outputFilename opts) of
    "--" -> return opts { outFile = stdout }
    _    -> do
      handle <- openFile (outputFilename opts) WriteMode
      return opts { outFile = handle }

printHelp :: IO ()
printHelp = putStr $ usageInfo "Usage: spl [OPTION]...\n" options
