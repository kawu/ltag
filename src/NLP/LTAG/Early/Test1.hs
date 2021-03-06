module NLP.LTAG.Early.Test1
( jean
, dort
, aime
, souvent
, nePas
, gram
) where


import qualified Data.IntMap as I

import           NLP.LTAG.Tree (AuxTree(AuxTree), Tree(FNode, INode))
import           NLP.LTAG.Early (treeTrav, auxTrav)


jean :: Tree String String
jean = INode "N" [FNode "jean"]


dort :: Tree String String
dort = INode "S"
    [ INode "N" []
    , INode "V"
        [FNode "dort"] ]


aime :: Tree String String
aime = INode "S"
    [ INode "N" []
    , INode "V"
        [FNode "aime"]
    , INode "N" [] ]


souvent :: AuxTree String String
souvent = AuxTree (INode "V"
    [ INode "V" []
    , INode "Adv"
        [FNode "souvent"] ]
    ) [0]


nePas :: AuxTree String String
nePas = AuxTree (INode "V"
    [ FNode "ne"
    , INode "V" []
    , FNode "pas" ]
    ) [1]


gram = I.fromList $ zip [0..]
    $ map treeTrav [jean, dort, aime]
   ++ map auxTrav [souvent, nePas]
