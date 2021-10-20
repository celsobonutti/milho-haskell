module Pipoquinha.Environment
  ( M(..)
  , StateCapable
  , ReaderCapable
  , ThrowCapable
  , CatchCapable
  , empty
  , insertValue
  , getValue
  , setValue
  , merge
  , TableRef
  , T(..)
  , Table(..)
  ) where

import           Capability.Constraints
import           Capability.Error
import           Capability.Reader
import           Capability.Sink
import           Capability.Source
import           Capability.State
import           Data.IORef
import qualified Data.Map                      as Map
import           Data.Map                       ( Map )
import qualified Pipoquinha.Error              as Error
import           Protolude               hiding ( All
                                                , MonadReader
                                                , ask
                                                , asks
                                                , empty
                                                , get
                                                , gets
                                                , modify'
                                                , put
                                                )
import           System.IO                      ( FilePath )

data Table sexp = Table
  { variables :: Map Text (IORef sexp)
  , parent    :: Maybe (IORef (Table sexp))
  }
  deriving Eq

insert :: Text -> IORef sexp -> Table sexp -> Table sexp
insert key value table =
  table { variables = Map.insert key value (variables table) }

mergeVariables :: Map Text (IORef sexp) -> Table sexp -> Table sexp
mergeVariables toMerge originalTable =
  originalTable { variables = Map.union toMerge (variables originalTable) }

type TableRef sexp = IORef (Table sexp)

data T sexp = T
  { table         :: TableRef sexp
  , executionPath :: FilePath
  }
  deriving Generic

newtype M sexp a = M {runM :: T sexp -> IO a}
  deriving (Functor, Applicative, Monad, MonadIO) via ReaderT (T sexp) IO

  deriving
    ( HasSource "table" (TableRef sexp)
    , HasReader "table" (TableRef sexp)
    ) via Field "table" "environment" (MonadReader (ReaderT (T sexp) IO))

  deriving
    ( HasThrow "runtimeError" Error.T
    , HasCatch "runtimeError" Error.T
    ) via MonadUnliftIO Error.T (ReaderT (T sexp) IO)

  deriving
    ( HasSource "tableState" (Table sexp)
    , HasSink   "tableState" (Table sexp)
    , HasState  "tableState" (Table sexp)
    ) via ReaderIORef (Rename "table" (Field "table" "environment" (MonadReader (ReaderT (T sexp) IO))))

  deriving
    ( HasSource "executionPath" FilePath
    , HasReader "executionPath" FilePath
    ) via Field "executionPath" "environment" (MonadReader (ReaderT (T sexp) IO))

type ReaderCapable sexp m
  = ( HasReader "table" (TableRef sexp) m
    , HasReader "executionPath" FilePath m
    , MonadIO m
    )

type StateCapable sexp m = (HasState "tableState" (Table sexp) m, MonadIO m)

type ThrowCapable m = HasThrow "runtimeError" Error.T m

type CatchCapable m = HasCatch "runtimeError" Error.T m

empty :: FilePath -> IO (T sexp)
empty executionPath = do
  let table = Table { variables = Map.empty, parent = Nothing }
  tableRef <- newIORef table
  return T { table = tableRef, executionPath }

insertValue :: StateCapable sexp m => Text -> sexp -> m ()
insertValue key value = do
  valueRef <- liftIO $ newIORef value
  modify' @"tableState" (insert key valueRef)

getValue
  :: (ThrowCapable m, MonadIO m) => Text -> TableRef sexp -> m (IORef sexp)
getValue key tableRef = do
  Table { variables, parent } <- liftIO $ readIORef tableRef
  case Map.lookup key variables of
    Just value -> return value
    Nothing    -> case parent of
      Nothing          -> throw @"runtimeError" (Error.UndefinedVariable key)
      Just parentTable -> getValue key parentTable

setValue
  :: (ThrowCapable m, MonadIO m) => Text -> sexp -> TableRef sexp -> m ()
setValue key newValue table = do
  value <- getValue key table
  liftIO $ writeIORef value newValue

merge :: StateCapable sexp m => Text -> T sexp -> m ()
merge prefix moduleEnvironment = do
  newTable <- liftIO . readIORef $ table moduleEnvironment
  let newVariables = Map.mapKeys (prefix <>) . variables $ newTable
  modify' @"tableState" (mergeVariables newVariables)
