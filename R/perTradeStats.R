#' calculate flat to flat per-trade statistics
#'
#' One 'trade' is defined as the entire time the symbol is not flat.
#' It may contain many transactions.  From the initial transaction that
#' moves the position away from zero to the last transaction that flattens the
#' position is all one 'trade' for the purposes of this function.
#' 
#' This is sometimes referred to as 'flat to flat' analysis.
#' 
#' Note that a trade that is open at the end of the measured period will
#' be marked to the timestamp of the end of the series.  
#' If that trade is later closed, the stats for it will likely change. 
#' This is 'mark to market' for the open position, and corresponds to
#' most trade accounting systems and risk systems in including the open
#' position in reporting.
#'  
#' @param Portfolio string identifying the portfolio
#' @param Symbol string identifying the symbol to examin trades for. If missing, the first symbol found in the \code{Portfolio} portfolio will be used
#' @param includeOpenTrade whether to process only finished trades, or the last trade if it is still open, default TRUE
#' @param tradeDef string to determine which definition of 'trade' to use. Currently "flat.to.flat" (the default) and "flat.to.reduced" are implemented.
#' @param \dots any other passthrough parameters
#' @author Brian G. Peterson, Jan Humme
#' @references Tomasini, E. and Jaekle, U. \emph{Trading Systems - A new approach to system development and portfolio optimisation} (ISBN 978-1-905641-79-6)
#' @return 
#' A \code{data.frame} containing:
#' 
#' \describe{
#'      \item{Start}{the \code{POSIXct} timestamp of the start of the trade}
#'      \item{End}{the \code{POSIXct} timestamp of the end of the trade, when flat}
#'      \item{Init.Pos}{the initial position on opening the trade}
#'      \item{Max.Pos}{the maximum (largest) position held during the open trade}
#'      \item{Num.Txns}{ the number of transactions included in this trade}
#'      \item{Max.Notional.Cost}{ the largest notional investment cost of this trade}
#'      \item{Net.Trading.PL}{ net trading P&L in the currency of \code{Symbol}}
#'      \item{MAE}{ Maximum Adverse Excursion (MAE), in the currency of \code{Symbol}}
#'      \item{MFE}{ Maximum Favorable Excursion (MFE), in the currency of \code{Symbol}}
#'      \item{Pct.Net.Trading.PL}{ net trading P&L in percent of invested \code{Symbol} price gained or lost}
#'      \item{Pct.MAE}{ Maximum Adverse Excursion (MAE), in percent}
#'      \item{Pct.MFE}{ Maximum Favorable Excursion (MFE), in percent}
#'      \item{tick.Net.Trading.PL}{  net trading P&L in ticks}
#'      \item{tick.MAE}{ Maximum Adverse Excursion (MAE) in ticks}
#'      \item{tick.MFE}{ Maximum Favorable Excursion (MFE) in ticks} 
#' }
#' @seealso \code{\link{chart.ME}} for a chart of MAE and MFE derived from this function, 
#' and \code{\link{tradeStats}} for a summary view of the performance
#' @export
perTradeStats <- function(Portfolio, Symbol, includeOpenTrade=TRUE, tradeDef="flat.to.flat", ...) {

    portf <- .getPortfolio(Portfolio)
    if(missing(Symbol)) Symbol <- ls(portf$symbols)[[1]]
    
    posPL <- portf$symbols[[Symbol]]$posPL
    
    instr <- getInstrument(Symbol)
    tick_value <- instr$multiplier*instr$tick_size

    tradeDef <- match.arg(tradeDef, c("flat.to.flat","flat.to.reduced"))
    
    trades <- list()
    switch(tradeDef,
        flat.to.flat = {
            # identify start and end for each trade, where end means flat position
            trades$Start <- which(posPL$Pos.Qty!=0 & lag(posPL$Pos.Qty)==0)
            trades$End <- which(posPL$Pos.Qty==0 & lag(posPL$Pos.Qty)!=0)
        },
        flat.to.reduced = {
            # find all transactions that bring position closer to zero ('trade ends')
            decrPos <- diff(abs(posPL$Pos.Qty)) < 0
            # find all transactions that open a position ('trade starts')
            initPos <- posPL$Pos.Qty!=0 & lag(posPL$Pos.Qty)==0
            # 'trades' start when we open a position, so determine which starts correspond to each end
            # add small amount to Start index, so starts will always occur before ends in StartEnd
            Start <- xts(initPos[initPos,which.i=TRUE],index(initPos[initPos])+1e-5)
            End   <- xts(decrPos[decrPos,which.i=TRUE],index(decrPos[decrPos]))
            StartEnd <- merge(Start,End)
            StartEnd$Start <- na.locf(StartEnd$Start)
            StartEnd <- StartEnd[!is.na(StartEnd$End),]
            # populate trades list
            trades$Start <- drop(coredata(StartEnd$Start))
            trades$End <- drop(coredata(StartEnd$End))
            # add extra 'trade start' if there's an open trade, so 'includeOpenTrade' logic will work
            if(last(posPL)[,"Pos.Qty"] != 0)
                trades$Start <- c(trades$Start, last(trades$Start))
        }
    )

    # if the last trade is still open, adjust depending on whether wants open trades or not
    if(length(trades$Start)>length(trades$End))
    {
        if(includeOpenTrade)
            trades$End <- c(trades$End,nrow(posPL))
        else
            trades$Start <- head(trades$Start, -1)
    }

    # pre-allocate trades list
    N <- length(trades$End)
    trades <- c(trades, list(
        Init.Pos = numeric(N),
        Max.Pos = numeric(N),
        Num.Txns = integer(N),
        Max.Notional.Cost = numeric(N),
        Net.Trading.PL = numeric(N),
        MAE = numeric(N),
        MFE = numeric(N),
        Pct.Net.Trading.PL = numeric(N),
        Pct.MAE = numeric(N),
        Pct.MFE = numeric(N),
        tick.Net.Trading.PL = numeric(N),
        tick.MAE = numeric(N),
        tick.MFE = numeric(N)))
    
    # calculate information about each trade
    for(i in 1:N)
    {
        timespan <- seq.int(trades$Start[i], trades$End[i])
        trade <- posPL[timespan]
        n <- nrow(trade)

        # calculate cost basis, PosPL, Pct.PL, tick.PL columns
        Pos.Qty <- trade[,"Pos.Qty"]                   # avoid repeated subsetting
        Pos.Cost.Basis <- cumsum(trade[,"Txn.Value"])
        Pos.PL <- trade[,"Pos.Value"]-Pos.Cost.Basis
        Pct.PL <- Pos.PL/abs(Pos.Cost.Basis)           # broken for last timestamp (fixed below)
        Tick.PL <- Pos.PL/abs(Pos.Qty)/tick_value      # broken for last timestamp (fixed below)
        Max.Pos.Qty.loc <- which.max(abs(Pos.Qty))     # find max position quantity location

        # position sizes
        trades$Init.Pos[i] <- Pos.Qty[1]
        trades$Max.Pos[i] <- Pos.Qty[Max.Pos.Qty.loc]

        # count number of transactions
        trades$Num.Txns[i] <- sum(trade[,"Txn.Value"]!=0)
        
        # investment
        trades$Max.Notional.Cost[i] <- Pos.Cost.Basis[Max.Pos.Qty.loc]
        
        # cash P&L
        trades$Net.Trading.PL[i] <- Pos.PL[n]
        trades$MAE[i] <- min(0,Pos.PL)
        trades$MFE[i] <- max(0,Pos.PL)
        
        # percentage P&L
        Pct.PL[n] <- Pos.PL[n]/abs(trades$Max.Notional.Cost[i])
        
        trades$Pct.Net.Trading.PL[i] <- Pct.PL[n]
        trades$Pct.MAE[i] <- min(0,Pct.PL)
        trades$Pct.MFE[i] <- max(0,Pct.PL)
        
        # tick P&L
        # Net.Trading.PL/position/tick value = ticks
        Tick.PL[n] <- Pos.PL[n]/abs(trades$Max.Pos[i])/tick_value
        
        trades$tick.Net.Trading.PL[i] <- Tick.PL[n]
        trades$tick.MAE[i] <- min(0,Tick.PL)
        trades$tick.MFE[i] <- max(0,Tick.PL)
    }
    trades$Start <- index(posPL)[trades$Start]
    trades$End <- index(posPL)[trades$End]

    return(as.data.frame(trades))
} # end fn perTradeStats


#' quantiles of per-trade stats
#' 
#' The quantiles of your trade statistics get to the heart of quantitatively 
#' setting rational stops and possibly even profit taking targets 
#' for a trading strategy or system.
#' When applied to theoretical trades from a backtest, they may help to adjust 
#' parameters prior to trying the strategy with real money.  
#' When applied to real historical trades, they should help in examining what 
#' is working and where there is room for improvement in a trading system 
#' or strategy.  
#' 
#' This function will use the \code{\link{quantile}} function to calculate 
#' quantiles of per-trade net P&L, MAE, and MFE using the output from
#' \code{\link{perTradeStats}}.  These quantiles are chosen by the \code{probs}
#' parameter and will be calculated for one or all of 
#' 'cash','percent',or 'tick', controlled by the \code{scale} argument.  
#' Quantiles will be calculated separately for trades that end positive (gains) 
#' and trades that end negative (losses), and will be denoted 
#' 'pos' and 'neg',respectively. 
#' 
#' Additionally, this function will return the MAE with respect to 
#' the maximum cumulative P&L achieved for each \code{scale} you request.
#' Tomasini&Jaekle recommend plotting MAE or MFE with respect to cumulative P&L 
#' and choosing a stop or profit target in the 'stable region'.  The reported 
#' max should help the user to locate the stable region, perhaps mechanically.
#' There is room for improvement here, but this should give the user 
#' information to work with in addition to the raw quantiles.  
#' For example, it may make more sense to use the max of a loess or
#' kernel or other non-linear fit as the target point. 
#' 
#' @param Portfolio string identifying the portfolio
#' @param Symbol string identifying the symbol to examin trades for. If missing, the first symbol found in the \code{Portfolio} portfolio will be used
#' @param \dots any other passthrough parameters
#' @param scale string specifying 'cash', or 'percent' for percentage of investment, or 'tick'
#' @param probs vector of probabilities for \code{quantile}
#' @author Brian G. Peterson
#' @references Tomasini, E. and Jaekle, U. \emph{Trading Systems - A new approach to system development and portfolio optimisation} (ISBN 978-1-905641-79-6)
#' @seealso \code{\link{tradeStats}}
#' @export 
tradeQuantiles <- function(Portfolio, Symbol, ..., scale=c('cash','percent','tick'),probs=c(.5,.75,.9,.95,.99,1)) 
{
    trades <- perTradeStats(Portfolio, Symbol, ...)
    
    #order them by increasing MAE and decreasing P&L (to resolve ties)
    trades <- trades[with(trades, order(-Pct.MAE, -Pct.Net.Trading.PL)), ]
    #we could argue that we need three separate sorts, but we'll come back to that if we need to
    
    trades$Cum.Pct.PL <- cumsum(trades$Pct.Net.Trading.PL) #NOTE: this is adding simple returns, so not perfect, but gets the job done
    trades$Cum.PL <- cumsum(trades$Net.Trading.PL)
    trades$Cum.tick.PL <- cumsum(trades$tick.Net.Trading.PL)
    # example plot
    # plot(-trades$Pct.MAE,trades$Cum.Pct.PL,type='l')
    #TODO: put this into a chart. fn
    
    post <- trades[trades$Net.Trading.PL>0,]
    negt <- trades[trades$Net.Trading.PL<0,]

    ret<-NULL
    for (sc in scale){
        switch(sc,
                cash = {
                    posq <- quantile(post$Net.Trading.PL,probs=probs)
                    names(posq)<-paste('posPL',names(posq))
                    
                    negq <- -1*quantile(abs(negt$Net.Trading.PL),probs=probs)
                    names(negq)<-paste('negPL',names(negq))
                    
                    posMFEq <-quantile(post$MFE,probs=probs)
                    names(posMFEq) <- paste('posMFE',names(posMFEq))
                    posMAEq <--1*quantile(abs(post$MAE),probs=probs)
                    names(posMAEq) <- paste('posMAE',names(posMAEq))
                    
                    negMFEq <-quantile(negt$MFE,probs=probs)
                    names(negMFEq) <- paste('negMFE',names(negMFEq))
                    negMAEq <--1*quantile(abs(negt$MAE),probs=probs)
                    names(negMAEq) <- paste('negMAE',names(negMAEq))
                    
                    MAEmax <- trades[which(trades$Cum.PL==max(trades$Cum.PL)),]$MAE
                    names(MAEmax)<-'MAE~max(cumPL)'
                    
                    ret<-c(ret,posq,negq,posMFEq,posMAEq,negMFEq,negMAEq,MAEmax)
                },
                percent = {
                    posq <- quantile(post$Pct.Net.Trading.PL,probs=probs)
                    names(posq)<-paste('posPctPL',names(posq))
                    
                    negq <- -1*quantile(abs(negt$Pct.Net.Trading.PL),probs=probs)
                    names(negq)<-paste('negPctPL',names(negq))
                    
                    posMFEq <-quantile(post$Pct.MFE,probs=probs)
                    names(posMFEq) <- paste('posPctMFE',names(posMFEq))
                    posMAEq <--1*quantile(abs(post$Pct.MAE),probs=probs)
                    names(posMAEq) <- paste('posPctMAE',names(posMAEq))
                    
                    negMFEq <-quantile(negt$Pct.MFE,probs=probs)
                    names(negMFEq) <- paste('negPctMFE',names(negMFEq))
                    negMAEq <--1*quantile(abs(negt$Pct.MAE),probs=probs)
                    names(negMAEq) <- paste('negPctMAE',names(negMAEq))
                    
                    MAEmax <- trades[which(trades$Cum.Pct.PL==max(trades$Cum.Pct.PL)),]$Pct.MAE
                    names(MAEmax)<-'%MAE~max(cum%PL)'
                    
                    ret<-c(ret,posq,negq,posMFEq,posMAEq,negMFEq,negMAEq,MAEmax)                
                },
                tick = {
                    posq <- quantile(post$tick.Net.Trading.PL,probs=probs)
                    names(posq)<-paste('posTickPL',names(posq))
                    
                    negq <- -1*quantile(abs(negt$tick.Net.Trading.PL),probs=probs)
                    names(negq)<-paste('negTickPL',names(negq))
                    
                    posMFEq <-quantile(post$tick.MFE,probs=probs)
                    names(posMFEq) <- paste('posTickMFE',names(posMFEq))
                    posMAEq <--1*quantile(abs(post$tick.MAE),probs=probs)
                    names(posMAEq) <- paste('posTickMAE',names(posMAEq))
                    
                    negMFEq <-quantile(negt$tick.MFE,probs=probs)
                    names(negMFEq) <- paste('negTickMFE',names(negMFEq))
                    negMAEq <--1*quantile(abs(negt$tick.MAE),probs=probs)
                    names(negMAEq) <- paste('negTickMAE',names(negMAEq))
                    
                    MAEmax <- trades[which(trades$Cum.tick.PL==max(trades$Cum.tick.PL)),]$tick.MAE
                    names(MAEmax)<-'tick.MAE~max(cum.tick.PL)'
                    
                    ret<-c(ret,posq,negq,posMFEq,posMAEq,negMFEq,negMAEq,MAEmax)
                }
        ) #end scale switch   
    } #end for loop
    
    #return a single column for now, could be multiple column if we looped on Symbols
    ret<-t(t(ret))
    colnames(ret)<-paste(Portfolio,Symbol,sep='.')
    ret
}

###############################################################################
# Blotter: Tools for transaction-oriented trading systems development
# for R (see http://r-project.org/) 
# Copyright (c) 2008-2015 Peter Carl and Brian G. Peterson
#
# This library is distributed under the terms of the GNU Public License (GPL)
# for full details see the file COPYING
#
# $Id$
#
###############################################################################
