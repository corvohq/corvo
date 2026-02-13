# jobbie-client (Haskell)

Minimal Haskell client module for Jobbie.

```haskell
import Jobbie.Client
import Data.Aeson (object, (.=))

main :: IO ()
main = do
  let client = JobbieClient "http://localhost:8080" Nothing
  r <- enqueue client "emails.send" (object ["to" .= ("user@example.com" :: String)])
  print r
```
