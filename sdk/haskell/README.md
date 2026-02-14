# corvo-client (Haskell)

Minimal Haskell client module for Corvo.

```haskell
import Corvo.Client
import Data.Aeson (object, (.=))

main :: IO ()
main = do
  let client = CorvoClient "http://localhost:8080" Nothing
  r <- enqueue client "emails.send" (object ["to" .= ("user@example.com" :: String)])
  print r
```
