#pandoc -t slidy -s sample.md -o sample.html
# -i is for iterative (slides advance one bullet point at a time)
pandoc -i -t slidy -s docker-06.md -o docker-06.html 
pandoc -t beamer docker-06.md -o docker-06.pdf