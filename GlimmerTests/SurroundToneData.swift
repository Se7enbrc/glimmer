// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

// Independently encoded on 2026-10-25 with libopus 1.6.1, restricted-lowdelay, 48 kHz, 240 samples.
// Channel n carries a 0.4-amplitude sine at 400 + 200*n Hz; no prior encoded fixtures were used.
// Eight mono lanes precede four stereo lanes. Each lane contains sixteen UInt16LE-sized packets.
enum SurroundToneData {
    static func packets(lane: Int) -> [Data] {
        guard let bytes = Data(base64Encoded: encoded[lane], options: .ignoreUnknownCharacters) else { return [] }
        var result: [Data] = []
        var cursor = 0
        while cursor + 2 <= bytes.count {
            let count = Int(bytes[cursor]) | Int(bytes[cursor + 1]) << 8
            cursor += 2
            guard count <= bytes.count - cursor else { return [] }
            result.append(bytes.subdata(in: cursor..<(cursor + count)))
            cursor += count
        }
        return result
    }

    private static let encoded = [
        """
        OQDof1TqbsedXGcwzXPTFYieoUwF7C0Yx+4tWvHMvlnSdzpQmpCjIK5f+2XEAonh9M1YIKTA1YMxiqwqAOizPlo8/eO5vv7zE+ma
        M4WlQQWapaeV/r/BLAmSbMm9WQXAOAB/yljr+SkA6LMU4toirko8zjrDwr0YKWSja9mCJucxkiGK7C94ohjLF43PAdhol/koAOiz
        FOLaIq5KPM46w8K9BSinTmnD9lLmPGD8jp7Moa5ELxueA9hol/koAOizFOLaIq5KPM46w8K9BSinTmnD9lLmPGD8jtp+ta5Erxue
        A9hol/koAOizFOLaIq5KPM46w8K9BRrygmnD9lLmPGD8jtp+ta5ErxueA9hol/koAOizFOLaIq5KPM46w8K9BRrygmnD9lLmPGD8
        jp7Moa5ELxueA9hol/ktAOizFOLaIq5KPM9TCXIiZzr25RNnV+EGV9URm184JjW9Ti9rF4w94DjbgaEt+ScA6LMU4toirko8z1MJ
        ciJnOvsUELSYT8Bd8Vwqbn8WK0D8HG3A0S35JgDosxTi2iKuSjzPUwlyImc6+xQQtJhPspdF94I6kwaA/BxtwNEt+ScA6LMU4toi
        rko8z1MJciJnOvsUELSYT8Bd8Vwqbn8WK0D8HG3A0S35JgDosxTi2iKuSjzPUwlyImc6+xQQtJhPspdF94I6kwaA/BxtwNEt+ScA
        6LMU4toirko8z1MJciJnOvsUELSYT8Bd8Vwqbn8WK0D8HG3A0S35JgDosxTi2iKuSjzPUwlyImc6+xDQ/phPspdF94I6kwaI/Bxt
        wNEt+ScA6LMU4toirko8z1MJciJnOvsQ0P6YT8Bd8Vwqbn8WK1D8HG3A0S35JgDosxTi2iKuSjzPUwlyImc6+xDQ/phPspdF94I6
        kwaI/BxtwNEt+Q==
        """,
        """
        OgDotOoloWhmqTjzNEHBS3nasYVmqUvrTgJoD+NFelsjZLJEHAmQvQpSt2y4kPrFEsorwx0MHPN/xnMQKgDosxG4jyUEzsmpXB7W
        TE4VilaqmLe8gc+5OhH0mMDgQ24cuAAAIjJZR9EpAOizCU0zqwZBf8r2u257NFFoxy2VAYMccGC50ijZF/YU3cfNMHxKFaHRKADo
        swlNM6sGQX/K9rtuezHWSGHPuCQIm+TiNcK3rDHCw4+ZIPiSFaHRKADoswlNM6sGQX/K9rtuezHWSGHPuCQIm+TiNcK3rDAmQ4+Z
        IPiSFaHRKADoswlNM6sGQX/K9rtuezHWSGHPuCQIm+TiNcK3rDHCw4+ZIPiSFaHRKADoswlNM6sGQX/K9rtuezHWSGHPuCQIm+Ti
        NcK3rDAmQ4+ZIPiSFaHRLADoswlNM6sGQX/M3gXbeCQPdZI6+A7SNTkoUIJxuQZZ+vOY3H4YPiXJEK0D0ScA6LMJTTOrBkF/zN4F
        23gkD3XX4zgcxNGkgmSF4zuFjOQni0kQrQPRJgDoswlNM6sGQX/M3gXbeCQPddeWRMTt2EN4WO4XXtmDi4tJEK0D0ScA6LMJTTOr
        BkF/zN4F23gkD3XXlkTExNGkf9IQlzuFjOQni0kQrQPRJgDoswlNM6sGQX/M3gXbeCQPddeWRMTt2EN4WO4XXtmDi4tJEK0D0ScA
        6LMJTTOrBkF/zN4F23gkD3XXSVFsxNGkf9IQlzuFjOQni0kQrQPRJgDoswlNM6sGQX/M3gXbeCQPdddJUWzt2EN4WO4XXtmDi4tJ
        EK0D0ScA6LMJTTOrBkF/zN4F23gkD3XXSVFsxNGkgmSF4zuFjOQni0kQrQPRJgDoswlNM6sGQX/M3gXbeCQPdddJUWzt2EN4WO4X
        XtmDi4tJEK0D0Q==
        """,
        """
        NgDon+KR3KofsGpFNj7UsoccYeDkomfU4xheW/4xCGqR58FSEzU9MUsyMBF01jm3d6DXhR04iZwqAOiecvtQJKaowQpj9k9OO0nY
        EJEYGxfj0uFgSu44sMFtgmWoCgB6V+RH/SsA6J5xyO7tEiAPDLjdKwRS3UW8wILHmXkP1wq4yCfsBxSoRyxeDn/cNYcJ/SoA6J5x
        yO7tEiAPDLjdKwRS3LKDxwRXy7d/La98xwgi6E6WWLwe/7g1hwr9KgDonnHI7u0SIA8MuN0rBFLcsoPHBFfLt38tr3zHCCLoTpZY
        vB7/uDWHCv0qAOieccju7RIgDwy43SsEUtyyg8cEV8u3fy2vfMcIIugTnli8Hv+4NYcL/SkA6J5xyO7tEiAPDLjdKwRS3Tqqnm8J
        WjKh2Czi3ppzURBrF4O/7hrDhf0nAOieccju7RIgDwy8hlOKQnHqn0CCB0+NqJPsYx9v4RH4XPkBrDhw/ScA6J5xyO7tEiAPDLyG
        U4pCceqfQH1vA42ok+xjH2/hEflc+QGsOHH9JgDonnHI7u0SIA8MvIZTikJx6p9AdD5p9oBpZ3ARMibSrnkBrDhy/ScA6J5xyO7t
        EiAPDLyGU4pCceqfQG+mH42ok+xjH2/hEflc+QGsOHP9JgDonnHI7u0SIA8MvIZTikJx6p9Aaw3R9oBpZ3ARMibSrnkBrDh0/ScA
        6J5xyO7tEiAPDLyGU4pCceqfQGZ1h42ok+xjH2/hEflc+QGsOHX9JgDonnHI7u0SIA8MvIZTikJx6p9AZnWF9oBpZ3ARMibSrnkB
        rDh2/ScA6J5xyO7tEiAPDLyGU4pCceqfQGHdO42ok+xjH2/hEfhc+QGsOHf9JgDonnHI7u0SIA8MvIZTikJx6p9AXUTt9oBpZ3AR
        MibSrnkBrDiX/Q==
        """,
        """
        NwDon+CpP0+ifHLCAOFYZl0iQSRH549SAGRIW+lEEExtPikV2QBKemKWYa1u+PClTj72CtuCIlGRKgDonlban9vIBFn0Ut2QijyX
        WTY1sGI7AupxOX5RyiRvOxu5axAAbXU2SvErAOieb+mqHbQU2wbRrjGJ5LkjMhWw8csA47j9wGf3SSimx4Q4+aMAU+b6wfEpAOie
        b+mqHbQU2wbRrjGJ5LkmJ1E8U7NivK9XdVE+G2oMtx8wgCnzfWDxKQDonm/pqh20FNsG0a4xieS5L76pPFOzYryvV3VRPhtqDLcf
        MIAp831g8SkA6J5v6aodtBTbBtGuMYnkuS++qTxTs2K8r1d1UT4badfXHzCAKfN9YPEpAOieb+mqHbQU2wbRrjGJ5Lk5VgE8U7Ni
        vK9XdVE+G2oMtx8wgCnzfWDxKQDonm/pqh20FNsG3WGNX936aaDuAnjzL/09QPQaLpPf+LynGjLc31hQ8ScA6J6CrhMH6PyJP4m3
        LYJk3HfduIy3KCEZV+tgdJQzNs3zGW7fWB/xJgDonoKuEwfo/Ik/ibctgmTcd924kR5ri2Rzn/REu3MZUsZbt6wP8ScA6J6CrhMH
        6PyJP4m3LYJk3HfduJh82CEZV+tgdJQzNs3zGW7fWB/xJgDonoKuEwfo/Ik/ibctgmTcd925OxQli2Rzn/REu3MRUsZbt6wP8ScA
        6J6CrhMH6PyJP4m3LYJk3HfduTpeL8cZV+tgdJQzNs3zGW7fWB7xJgDonoKuEwfo/Ik/ibctgmTcd925NDgCVWRzn/REu3MRUsZb
        t6wP8ScA6J6CrhMH6PyJP4m3LYJk3HfduS6Yf8cZV+tgdJQzNs3zGW7fWB7xJgDonoKuEwfo/Ik/ibctgmTcd925KesOVWRzn/RE
        u3MRUsZbt6wP8Q==
        """,
        """
        NQDon94eCIzuLonmdR6nuCZkIh17kW00+kUAYxeeir0V3n+s3kaemNDR0DdLvK9j5i1jYnN5iSwA6J6NXcXp2Yd2r2Is0YJho+2Y
        2/M4dJX5rd6dcLAy1StLcuWKAlABMqyPY+ktAOielHNDLHd6oQHUYuFaDOHu7c4QxswuhqzQX7Dz939cCYhWYWLLnvzfsN0t6SsA
        6JwI9BEajiLiRifSB46IC1H3A8iebIhuE9sKwBSRVR2mGqwVnF43BYhN6SwA6JwI9BEajiLiRifV5vWFFCLrYwwmWZaPUv3WtSRu
        MYraVdWLKzi+bewAuOknAOicCPQRGo4i4kYn1eb1hRQi7U+CKXFrWNI8wqHx4xwqgUyW9Yid6ScA6JwI9BEajiLiRifV5vWFFCLs
        45FL5WtY0jzCofHjHCoBTzcFiLvpJgDomKVDZysDaacBQN0ywiN2xA+6EdTrDT1FpYly1m9zE8S3YbJg6ScA6JilQ2crA2mnAUDd
        MsIjdsQPug8XU50ID7lrqFATSMyWCXCisqDpJgDomKVDZe/NX0w2CHDtlvmARAwNMnh38qER+Yw1+TzKiepbsNkw6ScA6JilQ2cr
        A2mnAUDa5jJG7YgfdBoQejNn3tPLa/wcymRphLhRWVDpJgDomKVDZysDaacBQNrmMkbtiB90GDU3mpwsaYOdmIcxE+JbqN0w6ScA
        6JilQ2crA2mnAUDa5jJG7YgfdBoQejNn3tPLa/wcymRphLhg2VDpJgDomKVDZysDaacBQNrmMkbtiB90GDU3mpwsaYOdmIcxE+pb
        qNlQ6ScA6JilQ2CqKBAtptgdwBwOrhQgX6WyprOndlZJtiKVT5MlhLhhWTDpJgDomKVDZysDaacBQNrmMkbtiB90GDU3mpwsaYOd
        mIc1E+JbqNlQ6Q==
        """,
        """
        NgDon9XlZ+y2qpFvyIA+4rZ377wkZSKLky5K6PPYvJzYdbn1dkATq+aRbmx3S6FelyGwHYAAtoMrAOiebUgU20TzZU3tN6WmBJ4G
        YL+BiwFqKhq3HU+XIdKjJIY6y3AB6KlIrOMsAOief4CQAJE/pdBFtD2AClnqMk+kpqIzP+03P6zZWm4PPNSeOTKCw+73sMvjKwDo
        mKVDZysDaacBPEKTisURmRVwwcC4KAp62fYd5bU/FleVxyeAF6uwQ0jjKwDomKVDZysDaacBPEKTisURmRdUToS4KAp62fYd5bU/
        FleVxyeAF+uQQ0TjKQDomKVDZysDaacBPEKTisURmX6konHia9zbC3qsUeO5UlXH9BfrsFVI4ycA6JilQ2crA2mnATxCk4rFEZmA
        vZfm+XQUR7TcvZBRLzj+F4uxQ0jjJgDomKVDZysDaacBPES4Shugvzd247gS15OjUBr+fBvop92nQh0I4ycA6JilQ2XYa65Ep8Qn
        sfOwUWwvnAVJawBKmj7ZdjB+tteSNJ0IehjjJgDomKVDZysDaacBPES4Shugvzd247gS15OjUBr+fBvop90nQp1I4ycA6JilQ2cr
        A2mnATxEuEoboL83duZGp/eN0zrnSkTo02vJEp0IepjjJgDomKVDYJOdk+JjM8KLjExzRplNUBhOMlpdGAbEGzV0U+0nQh1M4ycA
        6JilQ2crA2mnATxEuEoboL83duZGp/eN0zrnSkTo02vJEr0IehTjJgDomKVDZdhrrmPkftE73CRu0ZTKRm+N6mt4My3si9CdhV0n
        Qh1M4ycA6JilQ2crA2mnATxEuEoboL83du3zjgON0zrnSkTo02vJEp0IepTjJgDomKVDS7M4a7nyOM2B6w6T1yG+hV6LAREkhM5A
        Paf0U+0nQh1I4w==
        """,
        """
        MwDoioCr1dHl0tpvhTiYfVTtywkFvs+tR0FZuOoUTFdiD1m8jT0xSLbWH10K9BpcR1181s8uAOiJOMCM/gUvUSFdVYaWKOqGy/O4
        m4lATp1Diqq0pWa47zEuRCgZtRQAlwZdo/8sAOiJOLY5L3jQ9n/pkk8zkaRQRZihGVJbj8XjOH1yRIcTioFYsscS06OakJJ/KgDo
        hqv8/TBwfz06vNdNQyCn/o+/f+m+gbGAZ8WTstD6CaxZY4lhuvcRrX8qAOiGq/z9MHB/PTq8101DIKf7lHPn6b6BsYBnxZOy0PoJ
        rFljiWHS95GtfyoA6Iar/P0wcH89OrzXTUMgp/uG0o/pvoGxgGfFk7LQ+gmsWWOJYer3CST/KADohqv8/TBwfz06vNdNQyCpYxP2
        oTH7+d8RpmpdDTKFYLmsIfL3Eaz/JgDohqv8/TBwfz06vdyYqeBCQPgRvNGdklB7x6artkwNh1WzuQa2fycA6Ie0q3AIasqHcVFn
        ZRRqb9trJtHSl9xPqtqTn4FKrG5I8jQ4iWt/JgDoiABKmu2gKIMCIZxzhKaAEEDxzy6zL9SMz2usBXrA221TuQjY/ycA6IgASprs
        AE6jWO74UIMmcfvvvO6Qo72BnqtuQOVKc25LIjdyErH/JgDoh7SrcAiAzYb7DEdQg0XMPssf224AXtkJLztQyybA2WSuHERt/ycA
        6Iar/P0w136zM8vzKvsayn33Z3uy7QpSTQ61fc51jA2R4iu5DrZ/JgDohqv8/R8nZZkavUDiCgO4vvqWTo4nubKsIeudBiNth1Gz
        uQ42/ycA6Iar/P0wcH89Or3cmKngQkD4GH4c4l2Kj/dMS+pgMblUI2dxHKd/JgDohqv8/TBwfz06vdyYqeBCQPgY6tVtA+cl2wUT
        tkwNh1YsOQ63/w==
        """,
        """
        NgDoioCufdlxYq2A1xzrspEsvAf3lSjl4+MVJ5/GP7lzomqTQyQBKemPqKN7vroeHqPYrs9fYUwsAOiJKhigaGoBqHm674905ifa
        qNxqx/emGnluTUw8kreRoQeWsYFcgHt5IUP8LADoiTixZ53iEO8f42mc/DC/9lUt+ROuvAI3ZvtTlJ2CSjhDjk2uEsCMDELf/CkA
        6INvPg0LnBbbhBwYyU3QdZ0MDKP04JJxm3IwGxWHkOOTFwl9+oOZGnwpAOiDbz4NC5wW24QcGMlN0HW3eESj9OCScZtyMBsVh9Dj
        kxcJffqDmTh8KQDog28+DQucFtuEHBjJTdB7fyT0o/TgknGbcjAbFYfQ45MXCX36i5k4fCkA6Iar/P0wcH89KGBR+Js8oIebX1Ad
        8nBEdxbIARp8OuOTFwl96YOZLfwnAOiDbz4M4sBnnOQjov0mukGvjSw4LsgfoEUt59iy2HRGKWmUh2PIfCcA6Iar/P0wcH89KHIU
        luuYcfTN6Lm634C4x7s0ng14dEZSi0kOxaX8JgDohqv8/TBwfz0ochSW65hx9NhZjwzU417fMxOp939cKWukh2Kl/CcA6INvPgzi
        wGec5COi/Sa6Qa+QrzAOyB+gRS3n2LK4dEYpaLSHYqh8JgDohqv8/TBwfz0ochSW65hx9NhZjwzU417fMxOp539cKWukhmKl/CcA
        6Iar/PVFjllaGnCHHC/eHWeqibkr7l5sBR5S5g4Yd1wpaLSHYqP8JgDohqv8/TBwfz0ochSW65hx9OoD2wzU417fMxOp939cKWuk
        h2Kl/CcA6Iar/P0d/zbpEfPLcOsJaTKDOrwU58G/ZLe+Qh9od1wpa2kOxKX8JgDog28+DDIwlRt/5W5H+7sk8XTDNc6kcIFPxo1u
        Nd+FKJukh2KofA==
        """,
        """
        ZgDsf0rRt04ZCXCs/+SPW1xuzms6TFIpZaWtXJnTuoPonulQNTfcdUKa9YX+WBRtJrgNlFSgBmUUXxmIodv4EZaVVEW9l4DC1FZW
        gkPmfg7Ami6kegoIHqc/LYmLYwWZnsFhLDmmT3xIAOzIcTkpDGdJk1wcNprmEiIg7OKG99xeUG7n1aNqWDHgMRA3uvr7jS7MwPV8
        LFwNAsCqnQUpfhg51mPT8Jg7F20K/8yJGQyjbEcA7Mg1m7y177pd4a5reNuAiRV8ebJgX7RX3ZjjlOYnIKme0GjEH+f4uZ04Kj4l
        lFTcMtJarF8OPxYVkVQzIxVK/6qQaCzgu3FDAOzILrJto6aY1hUcC8vpGwcJkiOYAcCGmDijcJ0u7ecGirF4+aY+B9obd9Ueo1Ax
        M4T8YFwODiB1z4WTq9VfB8kiZ3FDAOzILrJto6aY1hUcC8vpGwcJkiOYAcCGmDijcJ0u7ecGirF4+aY+B9ohY6Ueo1ArjUbUYBAG
        DiF1z4WTq9VfB8kiZ3FDAOzILrJto6aY1hUcC8vpGwcJkiOYAcCGmDijcJ0u7ecGirF4+aY+B9obd9Ueo1AxM5RYRGQODiB1z4WT
        q9VfB8kiZ3FDAOzILrJto6aY1hUcC8vpGwcJkiOYAcCGmDijcJ0u7ecGirF4+aY+B9obd9Ueo1ArjUavNQgGDiB1z4WTq9VfB8ki
        Z3FdAOzILrJto6aY1hUcC8vpGwcYOkmK71ykpHr7phEVX5Og90wsxwLZUFwXt+wApW858/vWC5kLrokrA3VXcMDULO98gnmM6eKd
        cc8+J2oV09r1lb0Agq50dEkhd18rcU4A7Mgusm2jpppobapf++kbBxg6SYrvXKSaMZuvFThwzcgxISO/G3R26dVCCJBZ5oGD7lDo
        Jtpds2zdAnsHXPhaFdq9VezxBO4dEkRr4CtxRADsyC6ybaOmmmhtql/76RsHGDpJiu9cpKT8ycCVSaWuanOZ/Zmqtte2XZ+zTqsR
        H0V9PcRR2WACV9VezxBO4aSRGvgXcUUA7Mgusm2jpppobapf++kbBxg6SYrvXKSaMRq5/Eb1XjKJcAgRiciHfbs5Z1dP0yxCdJh8
        KMw+AIV71V7PEE7hpJEa+BdxRADsyC6ybaOmmmhtql/76RsHGDpJiu9cpKT8yXOiZ6WuanOZ/Zmqtte2XZ+zTqsRH0V9PcRR2WAC
        V9VezxBO4aSRGvgXcUUA7Mgusm2jpppobapf++kbBxg6SYrvXKSaMRq5/Eb1XjKJcAgRiciHfbs5Z1dP0yxCdJh8KMw+AIV71V7P
        EE7hpJEa+BdxRADsyC6ybaOmmmhtql/76RsHGDpJiu9cpKT8yXOiZ6WuanOZ/Zmqtte2XZ+zTqsRH0V9PcRR2WACV9VezxBO4aSR
        GvgXcUUA7Mgusm2jpppobapf++kbBxg6SYrvXKSaMPQaEtb1XjKJcAgRiciHfbs5Z1dP0yxCdJh8KMw+AIV71V7PEE7hpJEa+Bdx
        RADsyC6ybaOmmmhtql/76RsHGDpJiu9cpKT8fDPNhaWuanOZ/Zmqtte2XZ+zTqsRH0V9PcRR2WACV9VezxBO4aSRGvgXcQ==
        """,
        """
        YwDsfoo1ykzLxheWqKOXRHKTMW30tutfHwPfUY8yUIrAiwXQMyuE1fGmk8Txw/it3UL4wos/Uqlszmc2Tw9OgZUNyv8ZZyvmCmHd
        E/vCGymYOV5x5pMMULOjSJ3SjjZe6NM885ZMAOzJAQESddeOhaLz7SJP/DJrXz4yqwpGPcE8hENncoZmjqjlWJf3Ge33RP+ZHro3
        Q0L4STSVP9u2i8/3iMDiF1WAyIVVXNurZ+MfVnFKAOzIColMCT2CnrYG+tEfH20rxHrj2mr0dPB8xie9XZ8PjhMnAPP1qoMOlgsK
        aqVg1zKtNMeXI79EDeIwOIHXMAM/xPe0MhlXfd9xSQDsyRv4Sgz3DqtMnJYbFFGJLqrLs3lL+uVUfH7a6UaVG+tLnTQy15sdV9T2
        oTueLsnd3p1LynJpqtAox7B1z4JT6oqY2a1HeptxSADsw0UIyorYTvchgCnb193XEeUIjVSFERWvLH5Bi3+KkT1SFWe/nNMWz7Uu
        C+TObkkvpM9YAJET6gCnsHXPgkUM3t/5zS9hc3FIAOzDRQjKOVFd8qTIyrKvT7D70JAEk+3EstK2B8anl8cYs1WyqRQCrLbFcux2
        IOUERnVvGBhZ3tQOAGewdc+CRQzfnTnNT2F3cUgA7MNFCMiRl8IjtxPsTsEYkVTBRxrBi/OqXjkVfm4FwwZVHML/BRTu1W0qPafJ
        7NMTMkvCvfAkgEoA57B1z4JFDPe4OawrYXNxTQDsw0UIyosjgk5yR3YkLZdYX1gQPaWsoVe43jYhkNbByWRG1e4OdaqJZyW6LPMH
        pPiYOJUWEbsHbIQAB1Q9lXgHn9u1nzZzTtzwMZdTcUUA7MNFCMo5UV3ypMjKsq9PsPvQllOyDU3ZqXN6Tpbu72uwGf5metOgFcfa
        LKQlpBpd21wXES4bvFdePlGT1VzTtzgxh1NxRADsw0UIyjlsUQTLSTZXVSxdtcyHspNJrL5/kNvn+FL0h1SVXM5YHj3mMFJDHrm7
        4kF5yc771LFdeB5R2tUaw7M5LYdPcUUA7MNFCMo5bWUHmkx2V1UsXbXMh7KTSay+f5Db6D7YQjJUSQw3e8rnCy7JvTtwrDH5t4t3
        MqHQbFdehtGT1VzTszkxh1NxRADsw0UIyjlRXfKkyMqyr0+w+9CWU7INTdmpc3pN4yfK4HMjMOdxqjvGX8FJ3Y2krJB96V640LFd
        ej5R090c07M5MXdTcUUA7MNFCMo5bFEEy0k2V1UsXbXMh7KTSay+f5Db6B0J3MpQFww3e8rnCy7JvTtwrDH5t4t3MqHQ7FdenlHa
        1VrDMzkth1NxRADsyQOPWV1GSxe8aPOrdO0YcOki18CscdPZDQn9cUkN+4V385ARI6B+D5ELG1ZG1mkoGX22HyxXXq6wf3za1Ztd
        ouWXcUUA7MNFCMo5bdC2A6XaB8GpDsyhb4JNY1Letc5vmmV6s6CFfxDpLmWr7+rc1mMx4qj5PjRa1PwFjFdeplHb1RzTszkxh1Nx
        RADsw0UIyjlQs0jDgv2jCnQ6zkvbOOzRmLQ4iPjUz+cjbj+Hgf86A5OZAvrnDJTr21sK1KC3oyxXXr7R09Vc0zM4MYdTcQ==
        """,
        """
        YADsfnVrQowujxR6/drdagAB7DpXGu5jze2i+oDdkeSJytPrGYR1V9SrWNriKp9UY64bfCkSpf2iyfQGohrwHDu8zBnmvuF4i9uD
        09xb4tOAsOWpmGDYNJ0iMlFmgb2DSfFPAOzJLDmmUlXmOPIwnXSUA41+FiGGt52DJGzNoTigZJWXf0GN7E1GVBZReGF62RkYF1P7
        DNLHkFr56DX0oY2qEDiqKhbhAh//KeapEd+aR01OAOzICrI4ywjLdPrzTyBASuWChYyWj0FAcDNL4v4djTDmudIeusBckgnrvbL5
        rNj7GJ36zbq8coJH8UQKrzeIw8Ax9O/TO36HaK/C5XBbcUoA7Ma40B8aBH3zU+wtuwCaOfMTr0XfsSKSeIH72aubmHpyqlmeOipf
        etHW5r+hJSNkny13qpnFpEAKqgBnsHUmWKdTN1MX0qRVD3FKAOzGuCozq7XxH4I15Dzlj8QGTHG0PRFDTnP6OY5Ee950+SnlAIe4
        fBsdAar/dwUUMV1qx5OURbooqsYAZ7B1Jli2E/dRmVRoe19xSQDsw3JhAs4Rwol3peJpvzrpUl3cpLu/40lkQhTGJwriQdeOpGg9
        WyRGJRE1kne8K90nWXe5+fHoWjDeI+IHUmWkWP+LqVR2GidxSQDsw3JhAs4RwpTszEVWkQihYRgt70LWjl9sDFCQvUUi/C18LhWy
        cW9aRAXptl6JeG+CIZL6qpi3sAYw+IHUmUrs/+x5lxG5ZUdxRADsw3JhAs4Rwlo50JPvzIzdLy7EsQ4WiuJXY8WVXXYKy9DIcr7b
        jRu+A/cz+xZ5U8qMfUBGx9VqJ3qTX+mWOUPGTMkDcUUA7MNyYQLOEbz+QpuI825n6xi0ijduH9AHn4PsfMVAw+Zh1pRQRf3manw2
        D6F22qPrkt9ISHJjOUyV6ZNf2pY5RcZO2UNxRADsw3JhAs4RwpOF6u6htYPP/kZWV6CI8zPIWa4ypMeDVMT80JIrFJ/Bt9jfZZHd
        khl2NzoIJjVqJ3rjbsmWOUXGTslXcUUA7MNyYQLOEXn67wSoA4wLyv2OgxVSCz2mEk1+57dJoG4yqSR0mJlrIUAu1l6SbPzM2dPH
        RWiY1aid65NeyZY5RL5OyQNxRADsw3JhAs4RwW6jvVE0dd7RCrJe1iCjsClrtOqfNh9Wbxq3PlOwmtOcTevhpl1y4TP4r47Ox9Vq
        J3qTbtqWOUXGUNlDcUUA7MNyYQLOEbEBTkxe6eXYqsubXZpknfiSwQogv5pd6H/1F+MHMa0KRq4+sgHHSDVQIWUprXJjOUyV6qNe
        yZY5Rb5OyVNxRADsw3JhAs4Rwol3peJpvzrpUl3c2SzfiT4FGsHifxTo6Wyvu8VmTqIVYzk1GYiB9v0f2OIrh9VqJ3qTbsmWOUXG
        TskHcUUA7MNyYQLOCcPhwaWa+TgJNgqIeVcwhHJXW3CobN7Z13KOJCKPE0MCK8ZmHs7KiNfD7sYiSPJjOUyV6qNe2pY5RL5O2UNx
        RADsw3JhAs4Rwm89QEWlY7vhmPXcdXCCoCSv9vUD3nhFJhtEg9jhTPTOrWw4UiZbIOikD5cQJjVqJ3rTbsmWOUXGUMlXcQ==
        """,
        """
        YgDsfgE4skYDzUYJdvAptklY2krnv/jPET7mBmnPXPjzk70i+mMYCMQEjxZxrP+Kt9sl1qRXzni3K73ctKqiLey9OgZUNy5ZHipo
        8WrT04PTi7/hURFjX9yF6dNBdZb8+nvBFlEA7Mks1m1xr8Gi4qNuflpCfWyoNVoQutkTDK9bozwqXsWZk7BNXQCxg4LHPo2wKARl
        sG8aZ1/j0+4PSh8p2mpQpmQjr+BFUsPKC9kqFbojINtVTwDsx8uJk8wmp+PQCqfNfnEJ56LcNYeno04n9mZZw4dE1Sgx0MDHmqf9
        DjrD1A/FHORmFpCdkFYg7X1+uHzeIw98B9MmXkP7qKjCAG8B4ztxRwDsxvFvZpw77GMLaqKMQqvUWD7KR0xOL4YFUx+ccX/N0o0S
        1iRocYHd222vnESibZeQ7RvlyNDeGMewdSZQKmZX5aDePDfvcUYA7Ma4B0yQ3yI4c4+TJ2CWKJxsNx0bamKRmk7SBQUyCd4MZynv
        Oehp4SfQfHPF0NCB6E07nTDQGMewdSZQKmW//KkschYTcUYA7Ma4PzG1Azkp8WhOxGzB5/o/hPhO6eazcG/7TgUBqzyzNs9j3MAJ
        2kTzklWUaHk1lkeY5tx7gBnsHUmUCmc37KkA9dYPcUYA7Ma4B0yQ3yI4bpcT9p3JowMb8rJTacxyZvLLfmlkxJgoIa78uxWKSvaZ
        F/f7XO3ZR9MJSj9hgBnsHUmUUmcf+ZkscRYHcUwA7Me3ZAT5yUqt5WPzDmw+RkHCoQPSSA1YZer2uc+r8/W+/0+edNkZI/7y1hzS
        MRZK2p9b/Y3mrQsRpxloJ07e3r/QniYhg/HagYnLcUUA7Me3dKFa0F6BQ20tUpfJnyAWiMr35B17BvsrF4scmcgbG5cCPDcy32A8
        fnQvxMG3E2saxiXzQ2Z5Hu1NpmIczmwZbcNxRADsx7Q6XQha0q/v34RbsASoZWyT6NPEpFoevgHkhdhqT6PRZjTABvcWoAOVbMfT
        O7ltVYYl80Nm+HXqw3mYlz4m8EELcUUA7Ma4B0yQ3yI1SPFMifcuaviUo7hUNFnEQqwO8Qju1NTjFCTtDFcQbzcJLEYUo6hoNsm5
        QqKbcuiVC70N5mIg+lbwRYNxRADsxvRQ3bEGwR+AobUdyju4sk6S/Vh9cEuYbNrFBNmBX5KsvkPg5EGakdaf8oKrX9Lx5COJfNDZ
        nke6xHmIhzOXHGK7cUUA7Ma4B0yQ3yHodbkQNSjYOgUeQczNZzG43AQemuCf4vrJb0Y/s9pC1AXX6do4HwDtMXuVQqKbcuiVC70N
        5mIc+FbwSY9xRADsw3JRhpwOr4hCjGNWUCVINpcpG1lEav1e86DS+Q16k4UwMUhFU3AxLaZdQUpqnJKMhBQqzQ26JULuw3mYmD7t
        0gFDcUUA7Ma4PzG1AyvLQ4PQobnsEg3LgSoeo1x7Xl4gEJWg/31PyQpTxv2D+Alb338gYBzio9UzVCrNDbolQu9DeYiHM5b8aY9x
        RADsxvRQ3bEGwSKB7H9aWFuDoODkYGozbGjgYoO5GYY33eyKTiE9/e9eJ+ahpyGteqrJbNOJfNDZnke6w3mYhzOXHFL/cQ==
        """
    ]
}
