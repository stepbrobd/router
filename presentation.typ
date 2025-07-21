#import "@preview/polylux:0.4.0": *

#let title = "Internet scale routing with NixOS"
#let author = "Yifei Sun"
#let date = datetime(year: 2025, month: 9, day: 5)

#set document(title: title, author: author, date: date)

#set text(size: 20pt)
#set page(paper: "presentation-16-9", margin: 2cm, footer: [
  #set text(size: 12pt)
  #set align(horizon)
  #author #h(1fr) #toolbox.slide-number / #toolbox.last-slide-number
])

#slide[
  #set align(horizon)
  = Internet scale routing with NixOS

  #date.display("[month repr:long] [day padding:none], [year]")
]

#slide[
  == Tech stack

  - NixOS
    - systemd-networkd
    - nftables
  - Bird
  - Tailscale
]

#slide[
  #set align(center + horizon)
  == Questions?
]
